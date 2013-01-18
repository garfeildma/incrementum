
;;
;; <Program> -> <Expr>
;;            | (letrec ((lvar <Lambda>) ...) <Expr>)
;;  <Lambda> -> (lambda (var ...) <Expr>)
;;    <Expr> -> <Imm>
;;            | var
;;            | (if <Expr> <Expr> <Expr>)
;;            | (let ((var <Expr>) ...) <Expr>)
;;            | (app lvar <Expr> ... )
;;            | (prim <Expr>)
;;     <Imm> -> fixnum | boolean | char | null
;;

(define wordsize 8)

(define nil #x3F)

(define fixnum-shift 2)
(define fixnum-mask #x03)
(define fixnum-tag #x00)

(define boolean-t #x6F)
(define boolean-f #x2F)
(define boolean-bit #x06)
(define boolean-mask #xBF)

(define char-shift 8)
(define char-tag #x0F)
(define char-mask #x3F)


(define fixnum-bits
  (- (* wordsize 8) fixnum-shift))

(define fixnum-lower-bound
  (- (expt 2 (- fixnum-bits 1))))

(define fixnum-upper-bound
  (sub1 (expt 2 (- fixnum-bits 1))))

(define (fixnum? x)
  (and (integer? x) (exact? x) (<= fixnum-lower-bound x fixnum-upper-bound)))


;;
;; Immediate values (constants)
;;
(define (immediate? expr)
  (or (null? expr) (fixnum? expr) (boolean? expr) (char? expr)))

(define (immediate-rep x)
  (cond
   ((fixnum? x) (ash x fixnum-shift))
   ((boolean? x) (if x boolean-t boolean-f))
   ((null? x) nil)
   ((char? x) (logor (ash (char->integer x) char-shift) char-tag))
   (else #f)))

(define (emit-immediate x)
  (emit "	mov	$~s,	%rax" (immediate-rep x)))


;;
;; Unary Primitive Operations
;;
(define-syntax define-primitive
  (syntax-rules ()
    ((_ (prim-name si env arg* ...) b b* ...)
     (begin
       (putprop 'prim-name '*is-prim* #t)
       (putprop 'prim-name '*arg-count* (length '(arg* ...)))
       (putprop 'prim-name '*emitter* (lambda (si env arg* ...) b b* ...))))
    ))

(define (primitive? sym)
  (and (symbol? sym) (getprop sym '*is-prim*)))

(define (primitive-call? expr)
  (and (pair? expr) (primitive? (car expr))))

(define (primitive-arg-count sym)
  (and (primitive? sym) (getprop sym '*arg-count*)))

(define (primitive-emitter sym)
  (and (primitive? sym) (getprop sym '*emitter*)))

(define (check-primitive-call-args sym args)
  (= (primitive-arg-count sym) (length args)))

(define (emit-primitive-call si env expr)
  (let ((sym (car expr))
        (args (cdr expr)))
    (check-primitive-call-args sym args)
    (apply (primitive-emitter sym) si env args)))


(define (emit-primcall si env expr)
  (let ([prim (car expr)] [args (cdr expr)])
    (check-primcall-args prim args)
    (apply (primitive-emitter prim) si env args)))

(define (emit-boolean-transform . args)
  (emit "	~a	%al" (if (null? args) 'sete (car args)))
  (emit "	movzb	%al,	%rax")
  (emit "	sal	$~s,	%al" boolean-bit)
  (emit "	or	$~s,	%al" boolean-f))

(define (mask-primitive primitive label)
  (putprop label '*is-prim* #t)
  (putprop label '*arg-count* (primitive-arg-count primitive))
  (putprop label '*emitter* (primitive-emitter primitive)))

(define-primitive ($fxadd1 si env arg)
  (emit-expr si env arg)
  (emit "	add	$~s,	%rax" (immediate-rep 1)))

(define-primitive ($fxsub1 si env arg)
  (emit-expr si env arg)
  (emit "	sub	$~s,	%rax" (immediate-rep 1)))

(define-primitive ($fixnum->char si env arg)
  (emit-expr si env arg)
  (emit "	shl	$~s,	%rax" (- char-shift fixnum-shift))
  (emit "	or	$~s,	%rax" char-tag))

(define-primitive ($char->fixnum si env arg)
  (emit-expr si env arg)
  (emit "	shr	$~s,	%rax" (- char-shift fixnum-shift)))

(define-primitive ($fxlognot si env arg)
  (emit-expr si env arg)
  (emit "	shr	$~s,	%rax" fixnum-shift)
  (emit "	not	%eax")
  (emit "	shl	$~s,	%rax" fixnum-shift))

(define-primitive ($fxzero? si env arg)
  (emit-expr si env arg)
  (emit "	cmp	$~s,	%al" fixnum-tag)
  (emit-boolean-transform))

(map
 mask-primitive
 '($fxadd1 $fxsub1 $fixnum->char $char->fixnum $fxlognot $fxzero?)
 '( fxadd1  fxsub1  fixnum->char  char->fixnum  fxlognot  fxzero?))

(define-primitive (fixnum? si env arg)
  (emit-expr si env arg)
  (emit "	and	$~s,	%al" fixnum-mask)
  (emit "	cmp	$~s,	%al" fixnum-tag)
  (emit-boolean-transform))

(define-primitive (null? si env arg)
  (emit-expr si env arg)
  (emit "	cmp	$~s,	%al" nil)
  (emit-boolean-transform))

(define-primitive (boolean? si env arg)
  (emit-expr si env arg)
  (emit "	and	$~s,	%al" boolean-mask)
  (emit "	cmp	$~s,	%al" boolean-f)
  (emit-boolean-transform))

(define-primitive (char? si env arg)
  (emit-expr si env arg)
  (emit "	and	$~s,	%al" char-mask)
  (emit "	cmp	$~s,	%al" char-tag)
  (emit-boolean-transform))

(define-primitive (not si env arg)
  (emit-expr si env arg)
  (emit "	cmp	$~s,	%al" boolean-f)
  (emit-boolean-transform))


;;
;; Conditional Expressions
;;
(define unique-label
  (let ((count 0))
    (lambda ()
      (let ((label (format "L_~s" count)))
        (set! count (add1 count))
        label))
    ))

(define (list-expr? sym expr)
  (and (list? expr) (not (null? expr)) (eq? sym (car expr))))

(define (emit-label f)
  (emit "~a:" f))

;;; if
(define (if? expr)
  (and (list-expr? 'if expr) (= 4 (length expr))))

(define (if-predicate expr)
  (cadr expr))

(define (if-consequent expr)
  (caddr expr))

(define (if-alternate expr)
  (cadddr expr))

(define (emit-if si env tail expr)
  (let ((alternate-label (unique-label))
        (terminal-label (unique-label)))
    (emit-expr si env (if-predicate expr))
    (emit "	cmp	$~s,	%al" boolean-f)
    (emit "	je	~a" alternate-label)

    (emit-general-expr si env tail (if-consequent expr))
    (if (not tail) (emit "	jmp	~a" terminal-label))
    (emit-label alternate-label)
    (emit-general-expr si env tail (if-alternate expr))
    (emit-label terminal-label)))

;;; or, and
;; (define (emit-jump-block si env expr jump label)
;;   (let ((head (car expr)) (rest (cdr expr)))
;;     (emit-expr si env head)
;;     (emit "	cmp	$~s,	%al" boolean-f)
;;     (emit "	~a	~a" jump label)
;;     (unless (null? rest)
;;       (emit-jump-block si env rest jump label))))
;;
;; (define (emit-conditional-block default jump)
;;   (lambda (si env expr)
;;     (case (length expr)
;;       ((1) (emit-immediate default))
;;       ((2) (emit-expr si env (cadr expr)))
;;       (else
;;        (let ((end-label (unique-label)))
;;          (emit-jump-block si env (cdr expr) jump end-label)
;;          (emit-label end-label))))))

(define (and? expr)
  #f) ;;  (and (list? expr) (eq? (car expr) 'and)))

;; (define emit-and
;;   (emit-conditional-block #t "je"))

(define (or? expr)
  #f) ;; (and (list? expr) (eq? (car expr) 'or)))

;; (define emit-or
;;   (emit-conditional-block #f "jne"))


;;
;; Binary Primitive Operations
;;
(define (next-stack-index si)
  (- si wordsize))

(define (prev-stack-index si)
  (+ si wordsize))

(define (emit-binary-operator si env arg1 arg2)
  (emit-expr si env arg1)
  (emit-stack-save si)
  (emit-expr (next-stack-index si) env arg2))

(define (emit-stack-save si)
  (emit "	mov	%rax,	~s(%rsp)" si))

(define (emit-stack-load si)
  (emit "	mov	~s(%rsp),	%rax" si))

(define-primitive (fx+ si env arg1 arg2)
  (emit-binary-operator si env arg1 arg2)
  (emit "	add	~s(%rsp), %rax" si))

(define-primitive (fx- si env arg1 arg2)
  (emit-binary-operator si env arg2 arg1)
  (emit "	sub	~s(%rsp),	%rax" si))

(define-primitive (fx* si env arg1 arg2)
  (emit-binary-operator si env arg1 arg2)
  (emit "	shr	$2,	%rax")
  (emit "	imull	~s(%rsp)" si))

(define-primitive (fxlogor si env arg1 arg2)
  (emit-binary-operator si env arg1 arg2)
  (emit "	or	~s(%rsp), %rax" si))

(define-primitive (fxlognot si env arg1)
  (emit-expr si env arg1)
  (emit "	shr	$~s,	%rax" fixnum-shift)
  (emit "	not	%rax")
  (emit "	shl	$~s,	%rax" fixnum-shift))

(define-primitive (fxlogand si env arg1 arg2)
  (emit-binary-operator si env arg1 arg2)
  (emit "	and	~s(%rsp), %rax" si))

(define (define-binary-predicate op si env arg1 arg2)
  (emit-binary-operator si env arg1 arg2)
  (emit "	cmp	%rax,	~s(%rsp)" si)
  (emit-boolean-transform op))

(define-primitive (fx= si env arg1 arg2)
  (define-binary-predicate 'sete si env arg1 arg2))

(define-primitive (fx< si env arg1 arg2)
  (define-binary-predicate 'setl si env arg1 arg2))

(define-primitive (fx<= si env arg1 arg2)
  (define-binary-predicate 'setle si env arg1 arg2))

(define-primitive (fx> si env arg1 arg2)
  (define-binary-predicate 'setg si env arg1 arg2))

(define-primitive (fx>= si env arg1 arg2)
  (define-binary-predicate 'setge si env arg1 arg2))


;;
;; Local variables
;;
(define variable? symbol?)

(define (emit-variable-ref env expr)
  (let ((table-entry (assoc expr env)))
    (if table-entry (emit-stack-load (cdr table-entry))
        (error 'emit-variable-ref (format "Undefined variable ~s" expr)))))

(define (let? expr)
  (list-expr? 'let expr))

(define (let*? expr)
  (list-expr? 'let* expr))

(define let-bindings cadr)
(define let-body caddr)

(define (extend-env var si new-env)
  (cons (cons var si) new-env))

(define (emit-let si env tail expr)
  (define (process-let bindings si new-env)
    (cond
     ((null? bindings) (emit-general-expr si new-env tail (let-body expr)))
     (else
      (let ((binding (car bindings)))
        (emit-expr si (if (let*? expr) new-env env) (cadr binding))
        (emit-stack-save si)
        (process-let (cdr bindings)
                     (next-stack-index si)
                     (extend-env (car binding) si new-env))))))
  (process-let (let-bindings expr) si env))


;;
;; Procedures
;;
(define (emit-function-header f)
  (emit "	.text")
  (emit "	.globl	~a" f)
  (emit "	.type	~a,	@function" f)
  (emit-label f))

(define (emit-call label)
  (emit "	call	~a" label))

(define (emit-ret)
  (emit "	ret"))

(define lambda-fmls cadr)
(define lambda-body caddr)

(define (emit-lambda env)
  (lambda (expr label)
    (emit-function-header label)
    (let ((fmls (lambda-fmls expr))
          (body (lambda-body expr)))
      (let fn ((fmls fmls) (si (next-stack-index 0)) (env env))
        (cond
         ((null? fmls) (emit-expr si env body) (emit-ret))
         (else
          (fn (cdr fmls) (next-stack-index si) (extend-env (car fmls) si env))))
        ))
    ))

(define call-target car)
(define call-args cdr)

(define (app? expr env)
  (and (list? expr) (assoc (call-target expr) env)))

(define (emit-adjust-base si)
  (unless (= si 0) (emit "	add	$~s,	%rsp" si)))

(define (emit-app si env tail expr)
  (define (emit-arguments si args)
    (unless (null? args)
      (emit-expr si env (car args))
      (emit-stack-save si)
      (emit-arguments (next-stack-index si) (cdr args))))
  (emit-arguments (next-stack-index si) (call-args expr))
  (emit-adjust-base (prev-stack-index si))
  (emit-call (cdr (assoc (call-target expr) env)))
  (emit-adjust-base (- (prev-stack-index si))))

(define (letrec? expr)
  (list-expr? 'letrec expr))

(define letrec-bindings cadr)
(define letrec-body caddr)

(define (letrec-labels lvars)
  (map (lambda (lvar) (format "S_proc_~s" lvar)) lvars))

(define (make-initial-env lvars labels)
  (map cons lvars labels))

(define (emit-scheme-entry expr env)
  (emit-label "S_scheme_entry")
  (emit-expr (- wordsize) env expr)
  (emit-ret))

(define (emit-letrec expr)
  (let* ((bindings (letrec-bindings expr))
         (lvars (map car bindings))
         (lambdas (map cadr bindings))
         (labels (letrec-labels lvars))
         (env (make-initial-env lvars labels)))
    (for-each (emit-lambda env) lambdas labels)
    (emit-scheme-entry (letrec-body expr) env)))



;;
;; Compiler
;;
(define (emit-general-expr si env tail expr)
  (cond
   ((immediate? expr)      (emit-immediate expr))
   ((variable? expr)       (emit-variable-ref env expr))
   ((if? expr)             (emit-if si env tail expr))
   ((or (let? expr) (let*? expr)) (emit-let si env tail expr))
   ((app? expr env)        (emit-app si env tail expr))
   ((primitive-call? expr) (emit-primitive-call si env expr))
   (else (error 'emit-expr (format "~s is not a valid expression" expr)))))

(define (emit-expr si env expr)
  (emit-general-expr si env #f expr))

(define (emit-tail-expr si env expr)
  (emit-general-expr si env #t expr))

(define (emit-program-header)
  (emit-function-header "scheme_entry")
  (emit "	mov	%rsp,	%rcx")
  (emit "	sub	$~s,	%rsp" wordsize)
  (emit-call "S_scheme_entry")
  (emit "	mov	%rcx,	%rsp")
  (emit-ret))

(define (emit-program program)
  (emit-program-header)
  (cond
   ((letrec? program) (emit-letrec program))
   (else
    (emit-scheme-entry program (make-initial-env '() '())))))