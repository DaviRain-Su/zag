;; runtime-gerbil.ss — Gerbil/Gambit port of the zag live-image runtime.
;; Same protocol as runtime.ss (Chez): 4-byte LE u32 length + UTF-8 s-expr
;; payload frames on stdin/stdout.
;;
;; Runtime-specific adaptations from the Chez version:
;; - binary IO: read-u8 / read-u8vector (into a preallocated vector, returns
;;   count) / write-u8 / write-subu8vector on current-input/output-port;
;;   force-output flushes. No port settings needed — NUL/0x0A pass through.
;; - exceptions: with-exception-catcher (no R6RS guard); messages rendered
;;   with display-exception.
;; - escaping: canonical GAMBIT `write` form — named escapes plus \xHH; with
;;   LOWERCASE minimal hex (Chez uses uppercase). Decode accepts both cases.
;; - uncaught exceptions in gxi script mode print to STDOUT, which would
;;   corrupt the frame stream: the main loop is wrapped in a top-level
;;   catcher that reports to stderr and exits 70.

;; ---------- framing ----------

(define max-frame-bytes (* 4 1024 1024))

(define in-port (current-input-port))
(define out-port (current-output-port))
(define err-port (current-error-port))

(define (read-exact n)
  (let ((bv (make-u8vector n)))
    (let loop ((off 0))
      (if (= off n)
          bv
          (let ((got (read-subu8vector bv off n in-port)))
            (when (eof-object? got)
              (error 'frame-read "unexpected EOF inside frame payload"))
            (when (= got 0)
              (error 'frame-read "zero-byte read inside frame payload"))
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

;; ---------- kernel-tracked binding registry ----------

(define kernel.registry '())

(define (registry-record! name source)
  (let ((cell (assq name kernel.registry)))
    (if cell
        (set-cdr! cell source)
        (set! kernel.registry (cons (cons name source) kernel.registry)))))

(define (kernel.source-of name)
  (let ((cell (assq name kernel.registry)))
    (if cell (cdr cell) #f)))

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

(define (safe-eval-capture source)
  ;; Like safe-eval, but captures printed output so display cannot corrupt
  ;; the frame stream. Reply: (ok "<datum>" "<output>").
  (with-err-frame
    (lambda ()
      (let ((p (open-output-string)))
        (let ((v (parameterize ((current-output-port p))
                   (eval (read (open-input-string source))
                         (interaction-environment)))))
          (with-output-to-string
            (lambda ()
              (write `(ok ,(with-output-to-string (lambda () (write v)))
                          ,(get-output-string p))))))))))

(define (define-form-name form)
  (and (pair? form)
       (eq? (car form) 'define)
       (pair? (cdr form))
       (let ((target (cadr form)))
         (if (pair? target) (car target) target))))

(define (kernel-apply source)
  (with-err-frame
    (lambda ()
      (let ((p (open-input-string source)))
        (let read-all ((forms '()))
          (let ((f (read p)))
            (if (eof-object? f)
                (let ((forms (reverse forms)))
                  (for-each
                    (lambda (form)
                      (eval form (interaction-environment))
                      (let ((name (define-form-name form)))
                        (when name
                          (registry-record!
                            name
                            (if (= 1 (length forms))
                                source
                                (with-output-to-string
                                  (lambda () (write form))))))))
                    forms)
                  "(ok applied)")
                (read-all (cons f forms)))))))))

;; ---------- dispatch ----------

(define (dispatch f)
  (cond
    ((not (pair? f)) (frame-write "(err \"bad frame\")"))
    (else
      (case (car f)
        ((kernel.eval)  (frame-write (safe-eval (cadr f))))
        ((kernel.evalc) (frame-write (safe-eval-capture (cadr f))))
        ((kernel.apply) (frame-write (kernel-apply (cadr f))))
        ((kernel.echo)  (frame-write-sexp `(ok ,(cadr f))))
        ((kernel.quit)  (frame-write "(ok bye)") (exit 0))
        ((kernel.ping)  (frame-write "(ok pong)"))
        (else           (frame-write "(err \"unknown request\")"))))))

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

;; ---------- kernel primitives ----------

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

;; Spike protocol: (kernel.commit check-source expected) -> #t/#f.
(define (kernel.commit check-source expected)
  (frame-write-sexp `(kernel.commit ,check-source ,expected))
  (let ((f (kernel-wait (lambda (f)
                          (and (pair? f)
                               (memq (car f) '(kernel.ack kernel.err)))))))
    (eq? (car f) 'kernel.ack)))

(define (kernel.inspect name)
  (frame-write-sexp `(kernel.inspect ,name))
  (let ((f (kernel-wait (lambda (f)
                          (and (pair? f)
                               (eq? (car f) 'kernel.inspect.result))))))
    (cdr f)))

(define (provider.call sp hist-text)
  (frame-write-sexp `(provider.call ,sp ,hist-text))
  (cadr (kernel-wait (lambda (f)
                       (and (pair? f) (eq? (car f) 'provider.reply))))))

(define (tool.invoke tool path)
  (frame-write-sexp `(tool.invoke ,tool ,path))
  (kernel-wait (lambda (f)
                 (and (pair? f) (memq (car f) '(tool.result tool.error))))))

(define (kernel.hang)
  (let loop () (loop)))

;; Semantic gap (Gambit): (getenv "MISSING") raises "Unbound OS environment
;; variable" instead of returning #f. Shadow it with Chez semantics so
;; evaled code (e.g. env-check probes) behaves identically across runtimes.
(define (getenv name)
  (with-exception-catcher (lambda (e) #f) (lambda () (##getenv name))))


;; ---------- agent loop (spike-003; same semantics as runtime.ss) ----------

(define (conv-history)
  (frame-write "(conv.history)")
  (let ((f (kernel-wait (lambda (f)
                          (and (pair? f) (eq? (car f) 'kernel.history))))))
    (cdr f)))

(define (conv-append kind . fields)
  (frame-write-sexp `(conv.append ,kind ,@fields))
  (kernel-wait (lambda (f)
                 (and (pair? f) (eq? (car f) 'kernel.ack) (eq? (cadr f) 'conv))))
  #t)

(define (history->text entries)
  (with-output-to-string
    (lambda ()
      (for-each (lambda (e) (write e) (newline)) entries))))

(define (agent-provider-loop)
  (let* ((hist (conv-history))
         (reply (provider.call (system-prompt) (history->text hist))))
    (case (car reply)
      ((say)
       (conv-append (quote assistant) (cadr reply) (caddr reply))
       (cadr reply))
      ((call)
       (let ((tool (cadr reply)) (path (caddr reply)) (echo (cadddr reply)))
         (conv-append (quote tool-call) tool path echo)
         (agent-do-tool tool path)))
      (else (error (quote agent) "bad provider reply" reply)))))

(define (agent-do-tool tool path)
  (let ((r (tool.invoke tool path)))
    (conv-append (quote tool-result) tool (cadr r))
    (agent-provider-loop)))

(define (agent-continue)
  (let ((hist (conv-history)))
    (if (null? hist)
        (error (quote agent-continue) "empty conversation")
        (let ((tail (car (last-pair hist))))
          (case (car tail)
            ((user tool-result) (agent-provider-loop))
            ((tool-call) (agent-do-tool (caddr tail) (cadddr tail)))
            (else (error (quote agent-continue) "nothing to resume" (car tail))))))))

;; ---------- main loop ----------

(define (main-loop)
  (let loop ()
    (let ((raw (frame-read)))
      (unless (eof-object? raw)
        (if (eq? raw 'oversize)
            (frame-write "(err \"frame-too-large\")")
            (dispatch (read (open-input-string raw))))
        (loop)))))

;; gxi prints uncaught exceptions to STDOUT by default, which would corrupt
;; the frame stream. Catch at the top level: report to stderr, exit 70.
;; NOTE: kept as plain top-level code (no module main) on purpose — gxc's
;; module namespacing would hide these definitions from interaction-
;; -environment eval, which is fatal for a live image; gsc -exe (raw
;; Gambit compile) preserves eval visibility. See RESULTS.md round 5.
;; Also: Gambit never reports EOF on a stdin pipe to read-u8 in some
;; configurations, so polite shutdown goes through an explicit
;; (kernel.quit) frame, not EOF.
(define (runtime-main)
  (with-exception-catcher
    (lambda (e)
      (display-exception e err-port)
      (exit 70))
    (lambda () (main-loop))))

(runtime-main)
(exit 0)
