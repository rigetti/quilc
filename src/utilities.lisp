;;;; utilities.lisp
;;;;
;;;; Initial author: Eric Peterson

(in-package #:cl-quil)

(defun required-slot (slot-name)
  (check-type slot-name symbol)
  (error "The slot named ~S is required." slot-name))

(defmacro postpend (obj place)
  `(if ,place
       (push ,obj (cdr (last ,place)))
       (setf ,place (list ,obj))))

(defun make-adjustable-vector ()
  (make-array 4 :element-type t
                :initial-element nil
                :adjustable t
                :fill-pointer 0))

(defun vnth (index vector)
  "Like NTH, but for VECTORs."
  (aref vector index))

(defun (setf vnth) (val index vector)
  (setf (aref vector index) val))

(defmacro dohash (((key val) hash) &body body)
  `(maphash (lambda (,key ,val) ,@body)
            ,hash))
