;; runtime.ss — zag-live image: frame loop + kernel primitives.
;;
;; Frame protocol on stdin/stdout (binary):
;;   4-byte little-endian u32 length, then that many bytes of UTF-8 payload.
;;   Payload is exactly one s-expression, single line. String literals use
;;   canonical Chez `write` escaping both directions; decode is strict.
;;   Frames larger than max-frame-bytes are rejected on BOTH sides
;;   (inbound: discarded and answered with an err frame; the image does
;;   not die).
;;
;; Host -> image requests:
;;   (kernel.eval  "<source>")   eval one form -> (ok <datum>) / (err "<msg>")
;;   (kernel.apply "<source>")   eval 1+ top-level forms -> (ok applied)
;;   (kernel.echo  "<payload>")  -> (ok "<payload>")      (test/liveness)
;;   (kernel.ping)               -> (ok pong)             (watchdog probe)
;;   (kernel.ack <name>)         ack for a pending kernel request (no reply)
;;   (kernel.nack <name> "<reason-atom>")  negative ack; primitive raises
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

(import (chezscheme))

(define in-port (standard-input-port))
(define out-port (standard-output-port))

(define max-frame-bytes (* 4 1024 1024))

;; ---------- framing ----------

(define (read-exact n)
  (let ((bv (make-bytevector n)))
    (let loop ((off 0))
      (if (fx=? off n)
          bv
          (let ((got (get-bytevector-n! in-port bv off (fx- n off))))
            (when (eof-object? got)
              (error 'frame-read "unexpected EOF inside frame payload"))
            (loop (fx+ off got)))))))

(define (discard-exact n)
  (let ((chunk (make-bytevector 65536)))
    (let loop ((left n))
      (unless (fx=? left 0)
        (let ((got (get-bytevector-n! in-port chunk 0 (fxmin left 65536))))
          (when (eof-object? got)
            (error 'frame-read "unexpected EOF inside oversize frame"))
          (loop (fx- left got)))))))

(define (frame-read)
  ;; Returns the payload string, the eof-object on clean EOF, or the symbol
  ;; 'oversize (payload already discarded, stream still aligned).
  (let ((b0 (get-u8 in-port)))
    (if (eof-object? b0)
        b0
        (let* ((b1 (get-u8 in-port))
               (b2 (get-u8 in-port))
               (b3 (get-u8 in-port))
               (len (+ b0 (* b1 256) (* b2 65536) (* b3 16777216))))
          (if (> len max-frame-bytes)
              (begin (discard-exact len) 'oversize)
              (utf8->string (read-exact len)))))))

(define (frame-write payload)
  (let* ((bv (string->utf8 payload))
         (n (bytevector-length bv)))
    (put-u8 out-port (bitwise-and n #xff))
    (put-u8 out-port (bitwise-and (ash n -8) #xff))
    (put-u8 out-port (bitwise-and (ash n -16) #xff))
    (put-u8 out-port (bitwise-and (ash n -24) #xff))
    (put-bytevector out-port bv)
    (flush-output-port out-port)))

(define (frame-write-sexp sexp)
  (frame-write (with-output-to-string (lambda () (write sexp)))))

;; ---------- eval ----------

(define (condition->string e)
  (with-output-to-string
    (lambda ()
      (if (message-condition? e)
          (display (condition-message e))
          (display 'condition))
      (when (irritants-condition? e)
        (display " irritants=")
        (write (condition-irritants e))))))

(define (err-frame e)
  (with-output-to-string (lambda () (write `(err ,(condition->string e))))))

(define (safe-eval source)
  (call/cc
    (lambda (k)
      (guard (e (#t (k (err-frame e))))
        (let ((v (eval (read (open-string-input-port source))
                       (interaction-environment))))
          (with-output-to-string (lambda () (write `(ok ,v)))))))))

(define (kernel-apply source)
  ;; Eval every top-level form in SOURCE in order.
  (call/cc
    (lambda (k)
      (guard (e (#t (k (err-frame e))))
        (let ((p (open-string-input-port source)))
          (let read-all ((forms '()))
            (let ((f (read p)))
              (if (eof-object? f)
                  (let ((forms (reverse forms)))
                    (for-each
                      (lambda (form) (eval form (interaction-environment)))
                      forms)
                    "(ok applied)")
                  (read-all (cons f forms))))))))))

;; ---------- dispatch ----------

(define (dispatch f)
  (cond
    ((not (pair? f)) (frame-write "(err \"bad frame\")"))
    (else
      (case (car f)
        ((kernel.eval)  (frame-write (safe-eval (cadr f))))
        ((kernel.apply) (frame-write (kernel-apply (cadr f))))
        ((kernel.echo)  (frame-write-sexp `(ok ,(cadr f))))
        ((kernel.ping)  (frame-write "(ok pong)"))
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
          (let ((f (read (open-string-input-port raw))))
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

;; ---------- main loop ----------

(let loop ()
  (let ((raw (frame-read)))
    (unless (eof-object? raw)
      (if (eq? raw 'oversize)
          (frame-write "(err \"frame-too-large\")")
          (dispatch (read (open-string-input-port raw))))
      (loop))))

(exit 0)
