;; runtime.ss — zag-live image, Gambit binding (D-015).
;;
;; Frame protocol on stdin/stdout (binary):
;;   4-byte little-endian u32 length, then that many bytes of UTF-8 payload.
;;   Payload is exactly one s-expression, single line. String literals use
;;   canonical Gambit `write` escaping (lowercase \xhh;) both directions;
;;   the host decodes case-insensitively, strictly.
;;   Frames larger than max-frame-bytes are rejected on BOTH sides.
;;
;; Frame-stream purity (contract §3 R2): the image writes ONLY protocol
;; frames to stdout. gxi prints uncaught exceptions to STDOUT by default, so
;; the top-level catcher below routes diagnostics to stderr (bounded,
;; <= 4 KiB) and exits 70. Gambit ports do not reliably report stdin EOF —
;; polite stop is the explicit (kernel.quit) frame, never EOF.
;;
;; Host -> image requests:
;;   (kernel.self-id)            -> (ok (zag-live 1 gambit))  (boot handshake)
;;   (kernel.eval  "<source>")   eval one form -> (ok <datum>) / (err "<msg>")
;;   (kernel.apply "<source>")   eval 1+ top-level forms -> (ok applied)
;;   (kernel.echo  "<payload>")  -> (ok "<payload>")      (test/liveness)
;;   (kernel.ping)               -> (ok pong)             (watchdog probe)
;;   (kernel.quit)               -> (ok bye) then exit 0  (polite stop)
;;   (kernel.ack <name>)         ack for a pending kernel request (no reply)
;;   (kernel.nack <name> "<atom>")  negative ack; the primitive raises
;;   (kernel.err "<atom>")       negative ack for kernel.commit
;;   (port.nack provider|tool "<atom>")    port absent / port failed
;;   (provider.reply "<response>")         answer to provider.call
;;   (tool.reply "<result>")               answer to tool.invoke
;;   (kernel.inspect.result <alist>)       answer to kernel.inspect
;;
;; Image -> host requests (kernel primitives):
;;   (kernel.redefine <name> "<source>")
;;   (kernel.discard  <name>)
;;   (kernel.commit   "<reason>")                      ; default recorded check
;;   (kernel.commit   "<reason>" "<check>" "<expected>")
;;   (kernel.inspect  <name>)
;;   (provider.call   "<request-sexp>")     host ProviderPort
;;   (tool.invoke     <name> "<args-sexp>") host ToolPort

(define in-port (current-input-port))
(define out-port (current-output-port))
(define err-port (current-error-port))

(define max-frame-bytes (* 4 1024 1024))
(define max-stderr-diagnostics 4096)

;; ---------- framing ----------

(define (read-exact n)
  (let ((bv (make-u8vector n)))
    (let loop ((off 0))
      (if (= off n)
          bv
          (let ((got (read-subu8vector bv off n in-port)))
            (when (or (eof-object? got) (= got 0))
              (error 'frame-read "unexpected EOF inside frame payload"))
            (loop (+ off got)))))))

(define (discard-exact n)
  (let ((chunk (make-u8vector 65536)))
    (let loop ((left n))
      (unless (= left 0)
        (let ((got (read-subu8vector chunk 0 (min left 65536) in-port)))
          (when (or (eof-object? got) (= got 0))
            (error 'frame-read "unexpected EOF inside oversize frame"))
          (loop (- left got)))))))

(define (frame-read)
  ;; Returns the payload string, the eof-object on clean EOF, or the symbol
  ;; 'oversize (payload already discarded, stream still aligned).
  (let ((b0 (read-u8 in-port)))
    (if (eof-object? b0)
        b0
        (let* ((b1 (read-u8 in-port))
               (b2 (read-u8 in-port))
               (b3 (read-u8 in-port))
               (len (+ b0 (* b1 256) (* b2 65536) (* b3 16777216))))
          (if (> len max-frame-bytes)
              (begin (discard-exact len) 'oversize)
              (utf8->string (read-exact len)))))))

(define (frame-write payload)
  (let* ((bv (string->utf8 payload))
         (n (u8vector-length bv)))
    (write-u8 (bitwise-and n #xff) out-port)
    (write-u8 (bitwise-and (arithmetic-shift n -8) #xff) out-port)
    (write-u8 (bitwise-and (arithmetic-shift n -16) #xff) out-port)
    (write-u8 (bitwise-and (arithmetic-shift n -24) #xff) out-port)
    (write-subu8vector bv 0 n out-port)
    (force-output out-port)))

(define (frame-write-sexp sexp)
  (frame-write (with-output-to-string (lambda () (write sexp)))))

;; ---------- eval ----------

(define (exception->string e)
  (with-output-to-string
    (lambda () (display-exception e (current-output-port)))))

(define (with-err-frame thunk)
  (with-exception-catcher
    (lambda (e)
      (with-output-to-string (lambda () (write `(err ,(exception->string e))))))
    thunk))

(define (safe-eval source)
  (with-err-frame
    (lambda ()
      (let ((v (eval (read (open-input-string source))
                     (interaction-environment))))
        (with-output-to-string (lambda () (write `(ok ,v))))))))

(define (kernel-apply source)
  ;; Eval every top-level form in SOURCE in order.
  (with-err-frame
    (lambda ()
      (let ((p (open-input-string source)))
        (let read-all ((forms '()))
          (let ((f (read p)))
            (if (eof-object? f)
                (begin
                  (for-each
                    (lambda (form) (eval form (interaction-environment)))
                    (reverse forms))
                  "(ok applied)")
                (read-all (cons f forms)))))))))

;; ---------- dispatch ----------

(define image-identity '(zag-live 1 gambit))

(define (dispatch f)
  (cond
    ((not (pair? f)) (frame-write "(err \"bad frame\")"))
    (else
      (case (car f)
        ((kernel.self-id) (frame-write-sexp `(ok ,image-identity)))
        ((kernel.eval)  (frame-write (safe-eval (cadr f))))
        ((kernel.apply) (frame-write (kernel-apply (cadr f))))
        ((kernel.echo)  (frame-write-sexp `(ok ,(cadr f))))
        ((kernel.ping)  (frame-write "(ok pong)"))
        ((kernel.quit)  (frame-write "(ok bye)") (exit 0))
        (else           (frame-write "(err \"unknown request\")"))))))

;; Read frames until one satisfies accept?, dispatching any host requests
;; that arrive in between. Kernel primitives run *inside* an eval and are
;; therefore nested inside the main loop.
(define (kernel-wait accept?)
  (let loop ()
    (let ((raw (frame-read)))
      (when (eof-object? raw)
        (error 'kernel-wait "supervisor closed the pipe"))
      (if (eq? raw 'oversize)
          (begin (frame-write "(err \"frame-too-large\")") (loop))
          (let ((f (read (open-input-string raw))))
            (if (accept? f)
                f
                (begin (dispatch f) (loop))))))))

(define (ack-for? name)
  (lambda (f)
    (and (pair? f) (eq? (car f) 'kernel.ack) (eq? (cadr f) name))))

(define (ack-or-nack-for? name)
  (lambda (f)
    (and (pair? f)
         (memq (car f) '(kernel.ack kernel.nack))
         (pair? (cdr f))
         (eq? (cadr f) name))))

;; ---------- kernel primitives (visible to evaled code) ----------

(define (kernel.redefine name source)
  (frame-write-sexp `(kernel.redefine ,name ,source))
  (kernel-wait (ack-for? name))
  name)

(define (kernel.discard name)
  (frame-write-sexp `(kernel.discard ,name))
  (let ((f (kernel-wait (ack-or-nack-for? name))))
    (if (eq? (car f) 'kernel.nack)
        (error 'kernel.discard (caddr f))
        name)))

;; (kernel.commit reason) — default recorded check: replay completes and
;; every tracked binding resolves. (kernel.commit reason check expected) —
;; caller-supplied check, evaluated in the clean probe after replay.
(define (kernel.commit reason . check-pair)
  (frame-write-sexp `(kernel.commit ,reason ,@check-pair))
  (let ((f (kernel-wait (lambda (f)
                          (and (pair? f)
                               (memq (car f) '(kernel.ack kernel.err)))))))
    (if (eq? (car f) 'kernel.ack)
        #t
        (error 'kernel.commit (cadr f)))))

(define (kernel.inspect name)
  (frame-write-sexp `(kernel.inspect ,name))
  (let ((f (kernel-wait (lambda (f)
                          (and (pair? f)
                               (eq? (car f) 'kernel.inspect.result))))))
    (cdr f)))

;; ---------- host ports ----------

(define (port-call wait-kinds name)
  (lambda (f)
    (and (pair? f)
         (or (and (eq? (car f) 'port.nack)
                  (pair? (cdr f)) (eq? (cadr f) name))
             (memq (car f) wait-kinds)))))

(define (provider.call request)
  (frame-write-sexp `(provider.call ,request))
  (let ((f (kernel-wait (port-call '(provider.reply) 'provider))))
    (if (eq? (car f) 'port.nack)
        (error 'provider.call (caddr f))
        (cadr f))))

(define (tool.invoke name args)
  (frame-write-sexp `(tool.invoke ,name ,args))
  (let ((f (kernel-wait (port-call '(tool.reply) 'tool))))
    (if (eq? (car f) 'port.nack)
        (error 'tool.invoke (caddr f))
        (cadr f))))

(define (kernel.hang)
  (let loop () (loop)))

;; Gambit getenv RAISES on missing vars ("Unbound OS environment variable")
;; where Chez returns #f; shadow it so evaled probes see portable semantics.
(define (getenv name)
  (with-exception-catcher (lambda (e) #f) (lambda () (##getenv name))))

;; ---------- main loop + frame-stream purity ----------

(define (main-loop)
  (let loop ()
    (let ((raw (frame-read)))
      (unless (eof-object? raw)
        (if (eq? raw 'oversize)
            (frame-write "(err \"frame-too-large\")")
            (dispatch (read (open-input-string raw))))
        (loop)))))

;; Uncaught failure: bounded diagnostics to stderr, nonzero exit, never a
;; non-frame byte on stdout (contract §3).
(define (runtime-main)
  (with-exception-catcher
    (lambda (e)
      (let* ((full (exception->string e))
             (bounded (if (> (string-length full) max-stderr-diagnostics)
                          (substring full 0 max-stderr-diagnostics)
                          full)))
        (display bounded err-port)
        (exit 70)))
    (lambda () (main-loop))))

(runtime-main)
(exit 0)
