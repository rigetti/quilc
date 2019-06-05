;;;; simplify-arithmetic.lisp
;;;;
;;;; Author: Peter Karalekas

(in-package #:cl-quil)

(define-condition expression-not-simplifiable (serious-condition)
  ()
  (:documentation "A condition that is signalled any time an expression cannot be simplified. In general, a sub-condition should be preferred over signalling this one."))

(define-condition expression-not-linear (expression-not-simplifiable)
  ()
  (:documentation "A condition that is signalled any time an expression cannot be simplified due to being non-linear."))

(defun give-up-simplification (&key (because ':unknown))
  (ecase because
    (:not-linear (error 'expression-not-linear))
    (:unknown    (error 'expression-not-simplifiable))))

(define-transform simplify-arithmetic (simplify-arithmetics)
  "A transform which converts a parsed program with potentially complicated arithmetic to one that has simplified arithmetic expressions")

(defstruct affine-representation
  "Data structure that represents a linear expression."
  (constant 0d0 :type double-float)
  (coefficients (make-hash-table :test #'equalp) :type hash-table))

(defun expression->affine-representation (de)
  "Recursively construct an AFFINE-REPRESENTATION from an EXPRESSION (of type CONS)."
  (typecase de
    (double-float
     (make-affine-representation :constant de))
    (memory-ref
     (let ((rep (make-affine-representation)))
       (setf (gethash de (affine-representation-coefficients rep)) 1.0)
       rep))
    (cons
     (let ((left (expression->affine-representation (second de)))
           (right (expression->affine-representation (third de))))
       (ecase (car de)
         (+
          (let ((rep (make-affine-representation)))
            (setf (affine-representation-constant rep)
                  (+ (affine-representation-constant left)
                     (affine-representation-constant right)))
            (dohash ((ref coefficient) (affine-representation-coefficients left))
              (setf (gethash ref (affine-representation-coefficients rep)) coefficient))
            (dohash ((ref coefficient) (affine-representation-coefficients right))
              (if (gethash ref (affine-representation-coefficients rep))
                  (incf (gethash ref (affine-representation-coefficients rep)) coefficient)
                  (setf (gethash ref (affine-representation-coefficients rep)) coefficient)))
            rep))
         (-
          (let ((rep (make-affine-representation)))
            (setf (affine-representation-constant rep)
                  (- (affine-representation-constant left)
                     (affine-representation-constant right)))
            (dohash ((ref coefficient) (affine-representation-coefficients left))
              (setf (gethash ref (affine-representation-coefficients rep)) coefficient))
            (dohash ((ref coefficient) (affine-representation-coefficients right))
              (if (gethash ref (affine-representation-coefficients rep))
                  (decf (gethash ref (affine-representation-coefficients rep)) coefficient)
                  (setf (gethash ref (affine-representation-coefficients rep)) (- coefficient))))
            rep))
         (*
          (let ((rep (make-affine-representation)))
            (unless (or (zerop (hash-table-count (affine-representation-coefficients left)))
                        (zerop (hash-table-count (affine-representation-coefficients right))))
              (give-up-simplification) :because :not-linear)
            (setf (affine-representation-constant rep)
                  (* (affine-representation-constant left)
                     (affine-representation-constant right)))
            (dohash ((ref coefficient) (affine-representation-coefficients left))
              (setf (gethash ref (affine-representation-coefficients rep))
                    (* (affine-representation-constant right) coefficient)))
            (dohash ((ref coefficient) (affine-representation-coefficients right))
              (setf (gethash ref (affine-representation-coefficients rep))
                    (* (affine-representation-constant left) coefficient)))
            rep))
         (/
          (let ((rep (make-affine-representation)))
            (unless (zerop (hash-table-count (affine-representation-coefficients right)))
              (give-up-simplification :because :not-linear))
            (setf (affine-representation-constant rep)
                  (/ (affine-representation-constant left)
                     (affine-representation-constant right)))
            (dohash ((ref coefficient) (affine-representation-coefficients left))
              (setf (gethash ref (affine-representation-coefficients rep))
                    (/ coefficient (affine-representation-constant right))))
            rep)))))
    (otherwise (give-up-simplification))))

(defun affine-representation->expression (rep)
  "Build an EXPRESSION (of type CONS) from an AFFINE-REPRESENTATION, by first iterating through the memory references and their coefficients, and then adding the at the end."
  (let ((expr nil))
    (dohash ((ref coefficient) (affine-representation-coefficients rep))
      (unless (double= 0 coefficient)
        (setf expr (if expr
                       (list '+ (list '* coefficient ref) expr)
                       (list '* coefficient ref)))))
    (cond
      ((null expr)
       (affine-representation-constant rep))
      ((double= 0 (affine-representation-constant rep))
       expr)
      (t
       (list '+ (affine-representation-constant rep) expr)))))

(defgeneric simplify-arithmetic (thing)
  (:method ((thing t))
    thing)
  (:method ((thing gate-application))
    (map-into (application-parameters thing)
              (lambda (param)
                (handler-case
                    (typecase param
                      (constant
                       param)
                      (delayed-expression
                       (make-delayed-expression (delayed-expression-params param)
                                                (delayed-expression-lambda-params param)
                                                (affine-representation->expression
                                                 (expression->affine-representation
                                                  (delayed-expression-expression param)))))
                      (otherwise (give-up-simplification)))
                  (expression-not-linear () param)
                  (expression-not-simplifiable () param)))
              (application-parameters thing))))

(defun simplify-arithmetics (parsed-prog)
  "Simplify the arithmetic in all of the EXPRESSIONs in the APPLICATION-PARAMETERS of the GATE-APPLICATIONs of the EXECUTABLE-CODE of a PARSED-PROGRAM."
  (map nil #'simplify-arithmetic (parsed-program-executable-code parsed-prog))
  parsed-prog)
