;;;; csd-tests.lisp
;;;;
;;;; Author: Juan M. Bello-Rivas

(in-package #:cl-quil-tests)

(defun m= (a b &key (test #'quil::double=))
  "Returns T if matrices A and B are sufficiently close, NIL otherwise. The TEST function determines the tolerance for comparison."
  (flet ((norm-vec-inf (matrix)
           (reduce #'max (magicl::storage matrix) :key #'abs)))
    (funcall test 0.0d0 (norm-vec-inf (magicl:.- a b)))))

(defparameter *csd-dim* 16 "Dimension of unitary matrices used for testing purposes.")

(deftest test-csd-2x1 ()
  (let* ((m *csd-dim*)
         (n (floor m 2))
         (a (magicl:random-unitary (list m m) :type '(complex double-float)))
         (a3 (magicl:slice a (list 0 n) (list n m)))
         (a4 (magicl:slice a (list n n) (list m m)))
         (id (magicl:eye n :type '(complex double-float))))
    (multiple-value-bind (u1 u2 c s v2h)
        (quil::csd-2x1 a3 a4)
      (let ((u1h (magicl:conjugate-transpose u1))
            (u2h (magicl:conjugate-transpose u2))
            (v2 (magicl:conjugate-transpose v2h)))
        (is (m= id (magicl:@ u1h u1)))
        (is (m= id (magicl:@ u2h u2)))
        (is (m= id (magicl:@ v2h v2)))
        (is (m= a3 (magicl:@ u1 (magicl:scale s -1) v2h)))
        (is (m= a4 (magicl:@ u2 c v2h)))
        (is (m= id (magicl:.+ (magicl:@ c c) (magicl:@ s s))))))))

(deftest test-csd-equipartition ()
  (let* ((m *csd-dim*)
         (n (/ m 2))
         (a (magicl:random-unitary (list m m) :type '(complex double-float)))
         (a1 (magicl:slice a '(0 0) (list n n)))
         (a2 (magicl:slice a (list n 0) (list m n)))
         (a3 (magicl:slice a (list 0 n) (list n m)))
         (a4 (magicl:slice a (list n n) (list m m)))
         (id (magicl:eye n :type '(complex double-float))))
    (multiple-value-bind (u1 u2 v1h v2h theta)
        (quil::csd a n n)
      (let ((u1h (magicl:conjugate-transpose u1))
            (u2h (magicl:conjugate-transpose u2))
            (v1 (magicl:conjugate-transpose v1h))
            (v2 (magicl:conjugate-transpose v2h)))
        (is (m= id (magicl:@ u1h u1)))
        (is (m= id (magicl:@ u2h u2)))
        (is (m= id (magicl:@ v1h v1)))
        (is (m= id (magicl:@ v2h v2)))
        (let ((c (magicl:from-diag (mapcar #'cos theta) :type '(complex double-float)))
              (s (magicl:from-diag (mapcar #'sin theta) :type '(complex double-float))))
          (is (m= a1 (magicl:@ u1 c v1h)))
          (is (m= a2 (magicl:@ u2 s v1h)))
          (is (m= a3 (magicl:@ u1 (magicl:scale s -1) v2h)))
          (is (m= a4 (magicl:@ u2 c v2h))))))))

(deftest test-csd-uneven-partition ()
  (let* ((m *csd-dim*)
         (n 1)
         (a (magicl:random-unitary (list m m) :type '(complex double-float)))
         (a1 (magicl:slice a '(0 0) (list n n)))
         (a2 (magicl:slice a (list n 0) (list m n)))
         (a3 (magicl:slice a (list 0 n) (list n m)))
         (a4 (magicl:slice a (list n n) (list m m)))
         (id (magicl:eye n :type '(complex double-float))))
    (multiple-value-bind (u1 u2 v1h v2h theta)
        (quil::csd a n n)
      (let ((c (cos (first theta)))
            (s (sin (first theta)))
            (u1h (magicl:conjugate-transpose u1))
            (u2h (magicl:conjugate-transpose u2))
            (v1 (magicl:conjugate-transpose v1h))
            (v2 (magicl:conjugate-transpose v2h)))
        (is (m= id (magicl:@ u1h u1)))
        (is (m= id (magicl:@ u2h u2)))
        (is (m= id (magicl:@ v1h v1)))
        (is (m= id (magicl:@ v2h v2)))
        (is (m= a1 (magicl:scale (magicl:@ u1 v1h) c)))
        (let ((svec (let ((x (magicl:zeros (list (1- m) 1) :type '(complex double-float))))
                      (setf (magicl:tref x (- m 2) 0) s)
                      x)))
          (is (m= a2 (magicl:@ u2 svec v1h)))
          (is (m= a3 (magicl:@ u1 (magicl:conjugate-transpose (magicl:scale svec -1)) v2h))))
        (let ((cmat (let ((x (magicl:eye (1- m) :type '(complex double-float))))
                      (setf (magicl:tref x (- m 2) (- m 2)) c)
                      x)))
          (is (m= a4 (magicl:@ u2 cmat v2h))))))))
