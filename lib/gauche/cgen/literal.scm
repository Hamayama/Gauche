;;;
;;; gauche.cgen.literal - static literal data
;;;  
;;;   Copyright (c) 2004-2008  Shiro Kawai  <shiro@acm.org>
;;;   
;;;   Redistribution and use in source and binary forms, with or without
;;;   modification, are permitted provided that the following conditions
;;;   are met:
;;;   
;;;   1. Redistributions of source code must retain the above copyright
;;;      notice, this list of conditions and the following disclaimer.
;;;  
;;;   2. Redistributions in binary form must reproduce the above copyright
;;;      notice, this list of conditions and the following disclaimer in the
;;;      documentation and/or other materials provided with the distribution.
;;;  
;;;   3. Neither the name of the authors nor the names of its contributors
;;;      may be used to endorse or promote products derived from this
;;;      software without specific prior written permission.
;;;  
;;;   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;;;   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;;;   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
;;;   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
;;;   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
;;;   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
;;;   TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
;;;   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
;;;   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;;   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;;   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
;;;  
;;;  $Id: literal.scm,v 1.11 2008-05-10 13:35:57 shirok Exp $
;;;

(define-module gauche.cgen.literal
  (use srfi-1)
  (use srfi-13)
  (use srfi-42)
  (use gauche.parameter)
  (use gauche.sequence)
  (use gauche.cgen.unit)
  (use gauche.experimental.ref)
  (use gauche.experimental.lamb)
  (export <cgen-literal> cgen-c-name cgen-cexpr cgen-make-literal
          cgen-literal-static?
          define-cgen-literal cgen-literal
          cgen-allocate-static-datum
          )
  )
(select-module gauche.cgen.literal)

;;=============================================================
;; Static objects
;;

;; Many Scheme literals can be emitted as static C data.  So
;; we can delegate pointer adjustment task to system's ld.
;; Usually you don't need to touch this layer directly;
;; cgen-literal stuff (see "Scheme static values" below)
;; takes care of it.
;;
;; Static C data are categorized in two groups.  Constant structure,
;; which contains only statically determined pointers, and runtime
;; structure, which may contain slots that needs to be initialized
;; at runtime.  Each one is realized as static struct.  The constant
;; one is emitted first, so there's a constraint that the runtime one
;; can refer to the address of the member of the constant one, but not
;; vice versa.  (They're splitted so that each can be placed in
;; different sections of the compiled object).
;;
;; Each static data has to be 'allocated' before the code generation stage.
;; cgen-allocate-static-datum does the job.  It returns a string for C
;; expression representing a pointer to the C data.  Usually it may be
;; casted to SCM_OBJ.  You have to pass a thunk to generate initialization
;; code for the C variable.
;;
;; If the allocated data itself is a pointer type (e.g. ScmObj), there's
;; a possibility that the client uses its value, or the pointer to the
;; allocated data.  The latter only appears in the runtime structure,
;; since you can't use variable's value as a compile-time static constant.
;; You can tell cgen-allocate-static-datum that you're using value of
;; the allocated variable, by passing #f to init-thunk (the actual variable
;; is statically initialized by SCM_UNDEFINED (if c-type is ScmObj) or NULL
;; (otherwise).  It is the caller's responsibility to set appropriate value
;; within initialization stage.)
;;
;; Internal structure to register static data per type per category.
;; It is chained in <cgen-unit>'s static-data-list.
(define-class <cgen-static-data-list> ()
  ((category :init-keyword :category) ; 'constant or 'runtime
   (c-type :init-keyword :c-type)  ; symbol for C type, e.g. 'ScmObj
   (c-member-name :init-form (gensym "d")) ; member name in the C structure
   (count  :init-value 0)          ; # of allocated objs.
   (cpp-condition :init-form (cgen-cpp-condition)) ; cpp condition
   (init-thunks :init-value '())   ; thunks to generate initializers
                                   ;  constructed in rev order.
   ))

(define (static-data-c-struct-name category)
  (case category
    [(constant) "scm__sc"]
    [(runtime)  "scm__rc"]
    [else (error "[cgen internal] invalid category:" category)]))

(define (cgen-allocate-static-datum :optional (category 'runtime)
                                              (c-type   'ScmObj)
                                              (init-thunk #f))

  (define (ensure-static-data-list category c-type)
    (and-let* ([unit (cgen-current-unit)])
      (let* ([cppc (cgen-cpp-condition)]
             [dl   (find (^(dl) (and (eq? (~ dl'c-type) c-type)
                                     (eq? (~ dl'category) category)
                                     (equal? (~ dl'cpp-condition) cppc)))
                         (~ unit'static-data-list))])
        (or dl
            (rlet1 new (make <cgen-static-data-list>
                         :category category :c-type c-type)
              (push! (~ unit'static-data-list) new))))))
  
  (let ([dl (ensure-static-data-list category c-type)]
        [value-type? (not init-thunk)]
        [ithunk (or init-thunk (if (eq? c-type 'ScmObj) "SCM_UNBOUND" "NULL"))])
    (let1 count (~ dl'count)
      (slot-push! dl'init-thunks ithunk)
      (inc! (~ dl'count))
      (if value-type?
        (format "~a.~a[~a]" ; no cast, for this'll be also used as lvalue.
                (static-data-c-struct-name category)
                (~ dl'c-member-name)
                count)
        (format "SCM_OBJ(&~a.~a[~a])"
                (static-data-c-struct-name category)
                (~ dl'c-member-name)
                count)))))

(define (cgen-allocate-static-array category c-type init-thunks)
  (fold (lambda (init-thunk seed)
          (let1 cexpr (cgen-allocate-static-datum category c-type init-thunk)
            (or seed cexpr)))
        #f init-thunks))

(define-method cgen-emit-static-data ((unit <cgen-unit>))

  (define (emit-one-category category dls)
    (let1 dls (filter (^(dl) (eq? (~ dl'category) category)) dls)
      (unless (null? dls)
        (emit-struct-def category dls)
        (print "{")
        (dolist (dl dls) (emit-initializers dl))
        (print "};"))))

  (define (emit-struct-def category dls)
    (let1 name (static-data-c-struct-name category)
      (format #t "static ~astruct ~aRec {\n"
              (if (eq? category 'constant) "SCM_CGEN_CONST " "")
              name)
      (dolist [dl dls]
        (cond [(~ dl'cpp-condition) => (cut print "#if "<>)])
        (format #t "  ~a ~a[~a];\n" (~ dl'c-type) (~ dl'c-member-name)
                (~ dl'count))
        (cond [(~ dl'cpp-condition) => (cut print "#endif /*"<>"*/")]))
      (format #t "} ~a = " name)))

  (define (emit-initializers dl)
    (cond [(~ dl'cpp-condition) => (cut print "#if "<>)])
    (print "  {   /* "(~ dl'c-type)" "(~ dl'c-member-name)" */")
    (dolist [thunk (reverse (~ dl'init-thunks))]
      (if (string? thunk)
        (format #t "    ~a,\n" thunk)
        (begin (format #t "    ") (thunk) (print ","))))
    (print "  },")
    (cond [(~ dl'cpp-condition) => (cut print "#endif /*"<>"*/")]))

  (and-let* ([dls (~ unit'static-data-list)])
    (unless (null? dls)
      ;; This piece of code is required, for Win32 DLL doesn't like
      ;; structures to be const if it contains SCM_CLASS_PTR.  Doh!
      (print "#if defined(__CYGWIN__) || defined(GAUCHE_WINDOWS)")
      (print "#define SCM_CGEN_CONST /*empty*/")
      (print "#else")
      (print "#define SCM_CGEN_CONST const")
      (print "#endif"))
    (emit-one-category 'constant dls)
    (emit-one-category 'runtime dls)
    ))

;;=============================================================
;; Scheme static values
;;
;;   The class family of <cgen-literal> is used to generate
;;   'static' Scheme values in C.  If possible, the Scheme object
;;   will be statically allocated.  Otherwise, a C variable is defined
;;   and the object is allocated in the initialization routine.
;;
;;   To arrange a Scheme object to be dumped in C, just pass it to
;;   cgen-literal.  It returns an instance of <cgen-literal>
;;   (or its subclass).   You can extract a C expression (ScmObj type)
;;   that refers to the Scheme object by cgen-cexpr.
;;
;;   Note that cgen-cexpr may return a C expression that is only
;;   available after initialization (e.g. for a Scheme symbol, cgen-cexpr
;;   returns a ScmObj variable which is set in initialize routine).
;;   You have to check the result of cgen-literal-static? if you use
;;   cgen-cexpr result in the static definition.
;;
;;   To define a scheme value, use define-cgen-literal macro.
;;
;;    (define-cgen-literal <literal-class> <scheme-class>
;;      (slot ...)
;;      method ...)
;;
;;   Methods:
;;      (make (arg) ...)   -> returns instance of <literal-class>
;;
;;      (cexpr (self) ...) -> returns C expression of the literal.
;;                            If omitted, the C variable name that
;;                            hols the object is returned.
;;
;;      (extern (self) ...)
;;      (decl (self) ...) 
;;      (body (self) ...)
;;      (init (self) ...)  -> handle generation of each part.
;;                            If slot has <cgen-literal>, they
;;                            are traversed before these methods are
;;                            called.  Can be omitted.
;;
;;      (static (self) ...) -> used by cgen-literal-static?.
;;                            If omitted, #t is returned.
;;
;;   

;; <cgen-literal> base class ----------------------------------

(define-class <cgen-literal> (<cgen-node>)
  ((scope  :init-keyword :scope  :init-value 'local)
   (c-name :init-keyword :c-name
           :init-form (format "scm__~a" (cgen-unique-name)))
   ;; C-NAME: the C expression that returns the pointer
   ;;  to this literal.  Hence it's #f for immediate literals.
   ;;  It may have a thunk that computes the expression.
   (value  :init-keyword :value :init-value #f)
   ;; VALUE: the Scheme value this literal represents.
   ))

(define-method initialize ((node <cgen-literal>) initargs)
  (next-method)
  (when (~ node'c-name)
    (and-let* ([unit (cgen-current-unit)])
      (register-literal-value unit node)
      (slot-push! unit 'toplevels node))))

;; Fallback methods
;;
(define-method cgen-c-name ((node <cgen-literal>))
  (and-let* ([n (~ node'c-name)])
    (if (string? n) n (n))))

(define-method cgen-cexpr ((node <cgen-literal>))
  (cgen-c-name node))

(define-method cgen-make-literal (value)
  (error "cannot make a static C data for Scheme value:" value))

(define-method cgen-literal-static? (self) #t)

(define-method cgen-emit-xtrn ((node <cgen-literal>))
  (when (and (~ node'extern?) (cgen-c-name node))
    (print "extern ScmObj " (cgen-c-name node) ";")))

;; define-cgen-literal macro

(define-syntax define-cgen-literal
  (syntax-rules (make cexpr extern decl body init static)
    ;; loop for generating methods
    ((define-cgen-literal "methods" class scheme-class)
     #f)                                ;;end of loop
    ((define-cgen-literal "methods" class scheme-class
       (make (arg) . ?body) . rest)
     (begin
       (define-method cgen-make-literal ((arg scheme-class)) . ?body)
       (define-cgen-literal "methods" class scheme-class . rest)))
    ((define-cgen-literal "methods" class scheme-class
       (cexpr (self) . ?body) . rest)
     (begin
       (define-method cgen-cexpr ((self class)) . ?body)
       (define-cgen-literal "methods" class scheme-class . rest)))
    ((define-cgen-literal "methods" class scheme-class
       (extern (self) . ?body) . rest)
     (begin
       (define-method cgen-emit-xtrn ((self class)) . ?body)
       (define-cgen-literal "methods" class scheme-class . rest)))
    ((define-cgen-literal "methods" class scheme-class
       (decl (self) . ?body) . rest)
     (begin
       (define-method cgen-emit-decl ((self class)) . ?body)
       (define-cgen-literal "methods" class scheme-class . rest)))
    ((define-cgen-literal "methods" class scheme-class
       (body (self) . ?body) . rest)
     (begin
       (define-method cgen-emit-body ((self class)) . ?body)
       (define-cgen-literal "methods" class scheme-class . rest)))
    ((define-cgen-literal "methods" class scheme-class
       (init (self) . ?body) . rest)
     (begin
       (define-method cgen-emit-init ((self class)) . ?body)
       (define-cgen-literal "methods" class scheme-class . rest)))
    ((define-cgen-literal "methods" class scheme-class
       (static (self) . ?body) . rest)
     (begin
       (define-method cgen-literal-static? ((self class)) . ?body)
       (define-cgen-literal "methods" class scheme-class . rest)))
    ((define-cgen-literal "methods" class scheme-class
       _ . rest)
     (syntax-error "Unrecognized method clause in define-cgen-literal:" _))
    ;; Main entry
    ((define-cgen-literal class scheme-class slots . methods)
     (begin
       (define-class class (<cgen-literal>) slots)
       (define-cgen-literal "methods" class scheme-class . methods)))
    ;; Fallback
    ((define-cgen-literal . _)
     (syntax-error "malformed define-cgen-literal:" (define-cgen-literal . _)))
    ))
       
;; method cgen-literal returns a <cgen-literal> node for the
;; literal value of given Scheme value.  It first scans the current
;; unit's toplevel nodes with the same value, and returns it if found.
;; Otherwise, it creates a new node and register it to the toplevel if
;; necessary.
;; The check of value's class is a bit of kludge.  We want to share
;; equal strings or vectors; but there may be some objects which defines
;; object-equal? that returns #t with different class's instances.

(define (cgen-literal value)
  (or (and-let* ((unit (cgen-current-unit)))
        (lookup-literal-value unit value))
      (cgen-make-literal value)))

;; useful function to obtain initializer

(define (get-literal-initializer value)
  (if (cgen-literal-static? value)
    (cgen-cexpr value)
    "SCM_UNDEFINED"))

;; literal value management -----------------------------------

;; We want to share the same literals.  The criteria of this 'same' is
;; a bit complicated, and we can't use a hashtable for it (unless we have
;; a hashtable with completely customizable hash fn and cmp fn, which Gauche
;; doesn't have yet).  So we roll our own table, at least for the time being.
;;
;; NOTE: We don't share literals when they have different cpp-conditions,
;; even if they are the same otherwise.  Theoretically we can share if one
;; has cpp-condition and the other doesn't, but tracking those dependencies
;; is just a headache.  We just assume such sharing rarely occurs.

(define-constant .literal-hash-size. 32769)

(define (literal-value-hash literal)
  (define mask #x0fffffff)
  (define (rec val)
    (cond
     [(pair? val) (logand (+ (rec (car val)) (rec (cdr val))) mask)]
     [(vector? val) (fold (^(v r) (logand (+ (rec v) r) mask)) 0 val)]
     [(string? val) (logand (string-hash val) mask)]
     [(identifier? val) (logand (+ (rec (~ val'name))(rec (~ val'module))) mask)]
     [else (eqv-hash val)]))
  (modulo (rec literal) .literal-hash-size.))

(define (literal-value=? x y)
  (define (rec x y)
    (cond
     [(pair? x) (and (pair? y) (rec (car x) (car y)) (rec (cdr x) (cdr y)))]
     [(vector? x)
      (and (vector? y)
           (let1 len (vector-length x)
             (and (= len (vector-length y))
                  (every?-ec (: i len)
                             (rec (vector-ref x i) (vector-ref y i))))))]
     [(string? x) (and (string? y) (string=? x y))]
     [(identifier? x)
      (and (identifier? y)
           (eq? (~ x'name) (~ y'name))
           (eq? (~ x'module) (~ y'module)))]
     [else (and (eq? (class-of x) (class-of y)) (eqv? x y))]))
  (rec x y))

(define (ensure-literal-hash unit)
  (or (~ unit'literals)
      (rlet1 hash (make-vector .literal-hash-size. '())
        (set! (~ unit'literals) hash))))

(define (register-literal-value unit literal-obj)
  (let ([lh   (ensure-literal-hash unit)]
        [cppc (~ literal-obj'cpp-condition)]
        [h    (literal-value-hash (~ literal-obj'value))])
    (or (and-let* ([entry (find (^(e) (and (equal? (caar e) cppc)
                                           (literal-value=? (~ literal-obj'value)
                                                            (cdar e))))
                                (vector-ref lh h))])
          (set-cdr! entry literal-obj))
        (push! (vector-ref lh h) (acons cppc (~ literal-obj'value) literal-obj)))))

(define (lookup-literal-value unit val)
  (let ([lh (ensure-literal-hash unit)]
        [cppc (cgen-cpp-condition)])
    (and-let* ([entry (find (^(e) (and (equal? (caar e) cppc)
                                       (literal-value=? val (cdar e))))
                            (vector-ref lh (literal-value-hash val)))])
      (cdr entry))))

;; primitive values -------------------------------------------

;; boolean.  use predefined values.
(define-cgen-literal <cgen-scheme-boolean> <boolean>
  ()
  (make (value)
    (if value *cgen-scheme-true* *cgen-scheme-false*))
  (cexpr (self)
    (if (~ self'value) "SCM_TRUE" "SCM_FALSE")))

(define *cgen-scheme-true*
  (make <cgen-scheme-boolean> :c-name #f :value #t))
(define *cgen-scheme-false*
  (make <cgen-scheme-boolean> :c-name #f :value #f))

;; character.
(define-cgen-literal <cgen-scheme-char> <char>
  ()
  (make (value)
    (make <cgen-scheme-char> :c-name #f :value value))
  (cexpr (self)
    (format "SCM_MAKE_CHAR(~a)" (char->integer (~ self'value)))))

;; ()
(define-cgen-literal <cgen-scheme-null> <null>
  ()
  (make (value)
    (make <cgen-scheme-null> :c-name #f :value '()))
  (cexpr (self) "SCM_NIL"))

;; #<eof>
(define-cgen-literal <cgen-scheme-eof-object> <eof-object>
  ()
  (make (value)
    (make <cgen-scheme-eof-object> :c-name #f :value '()))
  (cexpr (self) "SCM_EOF"))

;; #<undef>
(define-cgen-literal <cgen-scheme-undefined-object> <undefined-object>
  ()
  (make (value)
    (make <cgen-scheme-undefined-object> :c-name #f :value '()))
  (cexpr (self) "SCM_UNDEFINED"))

;; string ------------------------------------------------------
;; (for now, we just deal with ASCII string w/o NUL.)

(define-cgen-literal <cgen-scheme-string> <string>
  ()
  (make (value)
    (make <cgen-scheme-string>
      :c-name (cgen-allocate-static-datum
               'constant 'ScmString
               (format "  SCM_STRING_CONST_INITIALIZER(~s, ~a, ~a)"
                       value (string-size value) (string-length value)))
      :value value))
  )

;; symbol ------------------------------------------------------

(define-cgen-literal <cgen-scheme-symbol> <symbol>
  ((symbol-name :init-keyword :symbol-name)) ;; <cgen-scheme-string>
  (make (value)
    (make <cgen-scheme-symbol> :value value
          :c-name (cgen-allocate-static-datum)
          :symbol-name (cgen-literal (symbol->string value))))
  (init (self)
    (print "  " (cgen-c-name self)
           " = Scm_Intern(SCM_STRING("
           (cgen-cexpr (~ self'symbol-name))
           ")); /* "(cgen-safe-comment (~ self'value))" */"))
  (static (self) #f)
  )

;; keyword ------------------------------------------------------

(define-cgen-literal <cgen-scheme-keyword> <keyword>
  ((keyword-name :init-keyword :keyword-name)) ;; <cgen-scheme-string>
  (make (value)
    (make <cgen-scheme-keyword> :value value
          :c-name (cgen-allocate-static-datum)
          :keyword-name (cgen-literal (keyword->string value))))
  (init (self)
    (print "  " (cgen-c-name self)
           " = Scm_MakeKeyword(SCM_STRING("
           (cgen-cexpr (~ self'keyword-name))
           ")); /* "(cgen-safe-comment (~ self'value))" */"))
  (static (self) #f)
  )

;; numbers -----------------------------------------------------

(define-cgen-literal <cgen-scheme-integer> <integer>
  ((string-rep :init-keyword :string-rep :init-value #f)
                                        ;; if value is too large to be C
                                        ;; literal, use string representation.
   )
  (make (value)
    (cond
     [(fixnum? value)
      (make <cgen-scheme-integer> :value value :c-name #f)]
     [(< (- (expt 2 31)) value (- (expt 2 32)))
      (make <cgen-scheme-integer> :value value
            :c-name (cgen-allocate-static-datum))]
     [else
      (make <cgen-scheme-integer> :value value
            :c-name (cgen-allocate-static-datum)
            :string-rep (cgen-literal (number->string value 16)))]))
  (cexpr (self)
    (or (cgen-c-name self)
        (if (positive? (~ self'value))
          (format "SCM_MAKE_INT(~aU)" (~ self'value))
          (format "SCM_MAKE_INT(~a)" (~ self'value)))))
  (init (self)
    (when (cgen-c-name self)
      ;; Kludge: we just assume the machine's 'long' can hold at least
      ;; 32 bits.  The right thing may be to insert #ifdefs to check if
      ;; we can use 64bit literal, but we'll leave it for later revision.
      (let ([val   (~ self'value)]
            [cname (cgen-c-name self)])
        (cond [(< (- (expt 2 31)) val 0)
               (print "  " cname " = Scm_MakeInteger("val");")]
              [(<= 0 val (- (expt 2 32) 1))
               (print "  " cname " = Scm_MakeIntegerU("val"U);")]
              [else
               (print "  " cname " = Scm_StringToNumber(SCM_STRING("
                      (cgen-cexpr (~ self'string-rep))"), 16, TRUE);")]))))
  (static (self)
    (if (cgen-c-name self) #f #t))
  )

(define-cgen-literal <cgen-scheme-real> <real>
  ((numer :init-keyword :numer :init-value #f)
   (denom :init-keyword :denom :init-value #f))
  (make (value)
    (make <cgen-scheme-real> :value value
          :c-name (cgen-allocate-static-datum)
          :numer (and (exact? value) (cgen-make-literal (numerator value)))
          :denom (and (exact? value) (cgen-make-literal (denominator value)))))
  (cexpr (self) (cgen-c-name self))
  (init (self)
    (let1 v (~ self'value)
      (if (exact? v)
        (print "  "(cgen-c-name self)" = Scm_MakeRational("(cgen-cexpr (~ self'numer))","(cgen-cexpr (~ self'denom))");")
        (print "  "(cgen-c-name self)" = Scm_MakeFlonum("v");"))))
  (static (self) #f))

(define-cgen-literal <cgen-scheme-complex> <complex>
  ()
  (make (value)
    (make <cgen-scheme-complex> :value value
          :c-name (cgen-allocate-static-datum)))
  (cexpr (self) (cgen-c-name self))
  (init (self)
    (let ([real (real-part (~ self'value))]
          [imag (imag-part (~ self'value))])
      (print "  "(cgen-c-name self)" = Scm_MakeComplex("real", "imag");")))
  (static (self) #f))

;; pair ---------------------------------------------------------

(define-cgen-literal <cgen-scheme-pair> <pair>
  ((car :init-keyword :car)
   (cdr :init-keyword :cdr))
  (make (value)
    (let* ([ca (cgen-literal (car value))]
           [cd (cgen-literal (cdr value))]
           [sobj (cgen-allocate-static-array
                  'runtime 'ScmObj
                  (list (get-literal-initializer ca)
                        (get-literal-initializer cd)))])
      (make <cgen-scheme-pair> :value value :car ca :cdr cd :c-name sobj)))
  (init (self)
    (let1 cname (cgen-cexpr self)
      (unless (cgen-literal-static? (~ self'car))
        (format #t "  SCM_SET_CAR(~a, ~a);\n" cname (cgen-cexpr (~ self'car))))
      (unless (cgen-literal-static? (~ self'cdr))
        (format #t "  SCM_SET_CDR(~a, ~a);\n" cname (cgen-cexpr (~ self'cdr))))
      ))
  )

;; vector -------------------------------------------------------

;; NB: ScmVector has variable part, so we can't directly initialize it.
;; We emit a vector as an array of ScmWord and cast it to ScmVector*
;; when using it.
(define-cgen-literal <cgen-scheme-vector> <vector>
  ((literals :init-keyword :literals) ;; list of cgen-literals for elements.
   )
  (make (value)
    (let* ([literals (map cgen-literal value)]
           [sobj (cgen-allocate-static-array
                  'runtime 'ScmObj
                  (list*
                   "SCM_OBJ(SCM_CLASS_STATIC_TAG(Scm_VectorClass)) /* <vector> */"
                   (format "SCM_OBJ(~a)" (length literals))
                   (map (^(lit) (if (cgen-literal-static? lit)
                                  (cgen-cexpr lit)
                                  "SCM_UNDEFINED"))
                        literals)))])
      (make <cgen-scheme-vector>
        :c-name sobj
        :value value
        :literals literals)))
  (init (self)
    (for-each-with-index
     (lambda (ind elt)
       (unless (cgen-literal-static? elt)
         (print "  ((ScmObj*)"(cgen-c-name self)")["(+ ind 2)"] = "(cgen-cexpr elt)";")))
     (~ self'literals)))
  )

;; char-set -----------------------------------------------------

(define-cgen-literal <cgen-scheme-char-set> <char-set>
  ()
  (make (value)
    (make <cgen-scheme-char-set> :value value
          :c-name (cgen-allocate-static-datum)))
  (init (self)
    (print "  {")
    (print "     ScmCharSet *cs = SCM_CHARSET(Scm_MakeEmptyCharSet());")
    (dolist (range (%char-set-ranges (~ self'value)))
      (format #t "     Scm_CharSetAddRange(cs, SCM_CHAR(~a), SCM_CHAR(~a));\n"
              (car range) (cdr range)))
    (print "     "(cgen-c-name self)" = SCM_OBJ(cs);")
    (print "  }"))
  (static (self) #f))

;; regexp -------------------------------------------------------

(define-cgen-literal <cgen-scheme-regexp> <regexp>
  ((source-string :init-keyword :source-string)
   (case-fold?    :init-keyword :case-fold?))
  (make (value)
    (make <cgen-scheme-regexp> :value value
          :c-name (cgen-allocate-static-datum)
          :source-string (cgen-literal (regexp->string value))
          :case-fold? (regexp-case-fold? value)))
  (init (self)
    (format #t "  ~a = Scm_RegComp(SCM_STRING(~a), ~a);\n"
            (cgen-c-name self)
            (cgen-c-name (~ self'source-string))
            (if (~ self'case-fold?) "SCM_REGEXP_CASE_FOLD" "0")))
  (static (self) #f))

;;=============================================================
;; Utilities
;;

(define cgen-unique-name
  (let1 counter 0
    (lambda () (format "~5,'0d" (inc! counter)))))

(provide "gauche/cgen/literal")

