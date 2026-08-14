;; runtime.ss — live image under Zig supervision.
;;
;; Frame protocol on stdin/stdout (binary):
;;   4-byte little-endian u32 length, then that many bytes of UTF-8 payload.
;;   Payload is exactly one s-expression, single-line, machine-escaped via
;;   Scheme `write` (Scheme -> supervisor) or Zig-equivalent escaping
;;   (supervisor -> Scheme).
;;
;; Supervisor -> Scheme frames:
;;   (kernel.eval  "<source>")   eval one form, reply (ok <value>) / (err "<msg>")
;;   (kernel.evalc "<source>")   same, but captures the form's printed output;
;;                               reply (ok "<value>" "<output>") / (err "<msg>")
;;   (kernel.apply "<source>")   eval 1+ top-level forms, record define sources,
;;                               reply (ok applied) / (err "<msg>")
;;   (kernel.echo  "<payload>")  reply (ok "<payload>")
;;   (kernel.ack <name>)         ack for a pending kernel.* request (no reply)
;;   (kernel.nack <name> "<reason>")  negative ack: the primitive raises a
;;                               readable condition instead of hanging
;;   (kernel.err  "<msg>")       negative ack for kernel.commit (no reply)
;;
;; Scheme -> supervisor frames (kernel requests, sent by the primitives below):
;;   (kernel.redefine <name> "<source>")
;;   (kernel.discard  <name>)
;;   (kernel.commit   "<check-source>" "<expected-value>")
;;   (kernel.inspect  <name>)   -> supervisor replies (kernel.inspect.result <alist>)
;;
;; Oversize frames (> max-frame-bytes, 4 MiB both sides) are discarded
;; inbound and answered with (err "frame-too-large"); the image keeps
;; running.

(import (chezscheme))

(define in-port (standard-input-port))
(define out-port (standard-output-port))

;; ---------- framing ----------

;; Max frame payload, BOTH directions. Must match max_frame_bytes in
;; src/main.zig. Oversize inbound frames are discarded byte-by-byte (so the
;; stream stays aligned) and rejected with an err frame — the image does
;; not die.
(define max-frame-bytes (* 4 1024 1024))

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
  ;; Consume n bytes from in-port in bounded chunks.
  (let ((chunk (make-bytevector 65536)))
    (let loop ((left n))
      (unless (fx=? left 0)
        (let ((got (get-bytevector-n! in-port chunk 0 (fxmin left 65536))))
          (when (eof-object? got)
            (error 'frame-read "unexpected EOF inside oversize frame"))
          (loop (fx- left got)))))))

(define (frame-read)
  ;; Returns the payload string, the eof-object on clean EOF, or the symbol
  ;; 'oversize when the length prefix exceeds max-frame-bytes (payload
  ;; already discarded, stream still aligned).
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

;; ---------- kernel-tracked binding registry ----------

;; assoc of name -> source text, for kernel.source-of introspection.
(define kernel.registry '())

(define (registry-record! name source)
  (let ((cell (assq name kernel.registry)))
    (if cell
        (set-cdr! cell source)
        (set! kernel.registry (cons (cons name source) kernel.registry)))))

(define (kernel.source-of name)
  (let ((cell (assq name kernel.registry)))
    (if cell (cdr cell) #f)))

;; ---------- eval helpers ----------

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
  ;; Eval a single form read from SOURCE; reply payload string.
  (call/cc
    (lambda (k)
      (guard (e (#t (k (err-frame e))))
        (let ((v (eval (read (open-string-input-port source))
                       (interaction-environment))))
          (with-output-to-string (lambda () (write `(ok ,v)))))))))

(define (safe-eval-capture source)
  ;; Like safe-eval, but also captures anything the form prints to
  ;; current-output-port (so `display` cannot corrupt the frame stream).
  ;; Reply: (ok "<datum-as-written>" "<captured-output>") — both fields are
  ;; string literals, easy for the supervisor to parse.
  (call/cc
    (lambda (k)
      (guard (e (#t (k (err-frame e))))
        ;; Chez: open-string-output-port returns TWO values (port, extractor).
        (let-values (((p get) (open-string-output-port)))
          (let ((v (parameterize ((current-output-port p))
                     (eval (read (open-string-input-port source))
                           (interaction-environment)))))
            (with-output-to-string
              (lambda ()
                (write `(ok ,(with-output-to-string (lambda () (write v)))
                            ,(get)))))))))))

(define (define-form-name form)
  (and (pair? form)
       (eq? (car form) 'define)
       (pair? (cdr form))
       (let ((target (cadr form)))
         (if (pair? target) (car target) target))))

(define (kernel-apply source)
  ;; Eval every top-level form in SOURCE in order; record define sources.
  ;; A single-form source is recorded raw (byte-identical to what the
  ;; supervisor journaled); multi-form sources are recorded re-printed.
  (call/cc
    (lambda (k)
      (guard (e (#t (k (err-frame e))))
        (let ((p (open-string-input-port source)))
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
                  (read-all (cons f forms))))))))))

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
        (else           (frame-write "(err \"unknown request\")"))))))

;; Read frames until one satisfies accept?, dispatching any kernel.*
;; requests that arrive in between. Used by the kernel primitives, which
;; run *inside* an eval and therefore nested inside the main loop.
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

;; Matches (kernel.ack <name>) or (kernel.nack <name> "<reason>").
(define (ack-or-nack-for? name)
  (lambda (f)
    (and (pair? f)
         (memq (car f) '(kernel.ack kernel.nack))
         (pair? (cdr f))
         (eq? (cadr f) name))))

;; ---------- kernel primitives (visible to evaled user code) ----------

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

(define (kernel.commit check-source expected)
  (frame-write-sexp `(kernel.commit ,check-source ,expected))
  (let ((f (kernel-wait (lambda (f)
                          (and (pair? f)
                               (memq (car f) '(kernel.ack kernel.err)))))))
    (eq? (car f) 'kernel.ack)))

;; Ask the supervisor what it knows about a binding. Returns the metadata
;; alist: ((source . <string-or-#f>) (status . committed|pending|unknown)
;;         (generation . <n-or-#f>) (dependents . <list-of-symbols>))
(define (kernel.inspect name)
  (frame-write-sexp `(kernel.inspect ,name))
  (let ((f (kernel-wait (lambda (f)
                          (and (pair? f)
                               (eq? (car f) 'kernel.inspect.result))))))
    (cdr f)))

(define (kernel.hang)
  (let loop () (loop)))

;; ---------- agent loop (spike-003) ----------
;;
;; Policy (system-prompt, tool-registry) lives in the genesis base as
;; ordinary kernel-tracked definitions — redefinable via kernel.redefine.
;; The mechanics below are fixed image infrastructure.
;;
;; Conversation store entries (Zig-owned, .work/conversation.sexp):
;;   (user        <seq> "<text>" <ts>)               appended by SUPERVISOR
;;   (assistant   <seq> "<text>" "<echo>" <ts>)      image-appended
;;   (tool-call   <seq> <tool> "<path>" "<echo>" <ts>) image-appended
;;   (tool-result <seq> <tool> "<result>" <ts>)      image-appended
;; <echo> is the system prompt the provider echoes back, proving which
;; policy produced the entry. The fake provider's script position is the
;; count of assistant + tool-call entries — derived from the store, so a
;; retried turn after a mid-turn kill deterministically gets the same
;; scripted response, and no entry can be duplicated.

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

(define (provider.call sp hist-text)
  (frame-write-sexp `(provider.call ,sp ,hist-text))
  (cadr (kernel-wait (lambda (f)
                       (and (pair? f) (eq? (car f) 'provider.reply))))))

(define (tool.invoke tool path)
  (frame-write-sexp `(tool.invoke ,tool ,path))
  (kernel-wait (lambda (f)
                 (and (pair? f) (memq (car f) '(tool.result tool.error))))))

(define (history->text entries)
  (with-output-to-string
    (lambda ()
      (for-each (lambda (e) (write e) (newline)) entries))))

;; One provider step: returns the final say text, or loops through tools.
(define (agent-provider-loop)
  (let* ((hist (conv-history))
         (reply (provider.call (system-prompt) (history->text hist))))
    (case (car reply)
      ((say)
       (conv-append 'assistant (cadr reply) (caddr reply))
       (cadr reply))
      ((call)
       (let ((tool (cadr reply)) (path (caddr reply)) (echo (cadddr reply)))
         (conv-append 'tool-call tool path echo)
         (agent-do-tool tool path)))
      (else (error 'agent "bad provider reply" reply)))))

(define (agent-do-tool tool path)
  (let ((r (tool.invoke tool path)))
    (conv-append 'tool-result tool (cadr r))
    (agent-provider-loop)))

;; Entry point used by the supervisor both for fresh turns (user entry
;; already journaled) and for recovery after a mid-turn kill: dispatch on
;; the last durable entry.
(define (agent-continue)
  (let ((hist (conv-history)))
    (if (null? hist)
        (error 'agent-continue "empty conversation")
        (let ((tail (car (last-pair hist))))
          (case (car tail)
            ;; fresh turn, or provider.call interrupted: (re)issue it; the
            ;; store-derived script position makes the retry deterministic.
            ((user tool-result) (agent-provider-loop))
            ;; tool-call was durable but the tool never ran: re-invoke from
            ;; the RECORDED call, not from a new provider reply.
            ((tool-call) (agent-do-tool (caddr tail) (cadddr tail)))
            (else (error 'agent-continue "nothing to resume" (car tail))))))))

;; ---------- main loop ----------

(let loop ()
  (let ((raw (frame-read)))
    (unless (eof-object? raw)
      (if (eq? raw 'oversize)
          (frame-write "(err \"frame-too-large\")")
          (dispatch (read (open-string-input-port raw))))
      (loop))))

(exit 0)
