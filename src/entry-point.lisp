;;;; pipe-compiler-entry-points.lisp
;;;;
;;;; fast entry point for compilation methods
;;;;
;;;; Author: Eric Peterson
;;;;
;;;; eventually, we will want this to look at argv for a filename from which it
;;;; can parse a chip/ISA specification. for now, we're going to bake such a
;;;; specification in.
;;;; ===sample input===
;;;; ANY CLASSICAL-FREE QUIL PROGRAM
;;;; ^D

(in-package #:quilc)


;; load and store bits of version information at compile time
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun system-version (system-designator)
    (let ((sys (asdf:find-system system-designator nil)))
      (if (and sys (slot-boundp sys 'asdf:version))
          (asdf:component-version sys)
          "unknown")))

  (defun git-hash (system)
    "Get the short git hash of the system SYSTEM."
    (let ((sys-path (namestring (asdf:system-source-directory system))))
      (multiple-value-bind (output err-output status)
          (uiop:run-program `("git" "-C" ,sys-path "rev-parse" "--short" "HEAD")
                            :output '(:string :stripped t)
                            :ignore-error-status t)
        (declare (ignore err-output))
        (if (not (zerop status))
            "unknown"
            output)))))

(eval-when (:compile-toplevel :load-toplevel)
  (alexandria:define-constant +QUILC-VERSION+
      (system-version '#:quilc)
    :test #'string=
    :documentation "The version of the quilc application.")

  (alexandria:define-constant +CL-QUIL-VERSION+
      (system-version '#:cl-quil)
    :test #'string=
    :documentation "The version of the CL-Quil library.")

  (alexandria:define-constant +GIT-HASH+
      (git-hash '#:quilc)
    :test #'string=
    :documentation "The git hash of the quilc repo.")
  )




(defparameter *program-name* "quilc")
(defparameter *compute-gate-depth* nil)
(defparameter *compute-runtime* nil)
(defparameter *compute-matrix-reps* nil)
(defparameter *topological-swaps* nil)
(defparameter *compute-gate-volume* nil)
(defparameter *gate-whitelist* nil)
(defparameter *gate-blacklist* nil)
(defparameter *without-pretty-printing* nil)
(defparameter *ISA-descriptor* nil)
(defparameter *verbose* (make-broadcast-stream))
(defparameter *protoquil* nil)


;; NOTE: these can't have default values b/c they don't survive serialization
(defparameter *json-stream* (make-broadcast-stream))
(defparameter *human-readable-stream* (make-broadcast-stream))
(defparameter *quil-stream* (make-broadcast-stream))

(defparameter *statistics-dictionary* (make-hash-table :test #'equal))

(defparameter *option-spec*
  '((("compute-gate-depth" #\d) :type boolean :optional t :documentation "prints compiled circuit gate depth; requires -p")
    (("compute-gate-volume") :type boolean :optional t :documentation "prints compiled circuit gate volume")
    (("compute-runtime" #\r) :type boolean :optional t :documentation "prints compiled circuit expected runtime; requires -p")
    (("compute-matrix-reps" #\m) :type boolean :optional t :documentation "prints matrix representations for comparison; requires -p")
    (("show-topological-overhead" #\t) :type boolean :optional t :documentation "prints the number of SWAPs incurred for topological reasons")
    (("gate-blacklist") :type string :optional t :documentation "when calculating statistics, ignore these gates")
    (("gate-whitelist") :type string :optional t :documentation "when calculating statistics, consider only these gates")
    (("without-pretty-printing") :type boolean :optional t :documentation "turns off pretty-printing features")
    (("verbose") :type boolean :optional t :documentation "verbose compiler trace output")
    (("json-serialize" #\j) :type boolean :optional t :documentation "serialize output as a JSON object")
    (("isa") :type string :optional t :documentation "set ISA to one of \"8Q\", \"20Q\", \"16QMUX\", or path to QPU description file")
    (("protoquil" #\p) :type boolean :optional t :documentation "restrict input/output to ProtoQuil")
    (("help" #\? #\h) :optional t :documentation "print this help information and exit")
    (("server-mode" #\S) :type boolean :optional t :documentation "run as a server")
    (("port") :type integer :optional t :documentation "port to run the server on")
    (("time-limit") :type integer :initial-value 0 :documentation "time limit for server requests (0 => unlimited, ms)")
    (("version" #\v) :optional t :documentation "print version information")))

(defun slurp-lines (&optional (stream *standard-input*))
  (flet ((line () (read-line stream nil nil nil)))
    (with-output-to-string (s)
      (loop :for line := (line) :then (line)
         :while line
         :do (write-line line s)))))

(defun print-quil-list (executable-code stream)
  (loop :for instr :in executable-code :do
     (progn
       (quil::print-instruction instr stream)
       (format stream "~%"))))

(defun reload-foreign-libraries ()
  (locally
        (declare #+sbcl (sb-ext:muffle-conditions style-warning))
      (handler-bind (#+sbcl (style-warning #'muffle-warning))
        (cffi:load-foreign-library 'magicl.foreign-libraries::libgfortran)
        (cffi:load-foreign-library 'magicl.foreign-libraries::libblas)
        (cffi:load-foreign-library 'magicl.foreign-libraries::liblapack)
        (cffi:load-foreign-library 'magicl.foreign-libraries::libexpokit))))

(defun print-matrix-with-comment-hashes (matrix &optional (stream *standard-output*))
  (format stream "~d"
          (cl-ppcre:regex-replace-all
           (coerce #(#\Newline) 'string)
           (with-output-to-string (s)
             (princ matrix s))
           (coerce #(#\Newline #\#) 'string))))

(defun show-help ()
  (format t "Usage:~%")
  (format t "  ~A [options]~%" *program-name*)
  (format t "Options:~%")
  (command-line-arguments:show-option-help *option-spec* :sort-names t))

(defun show-version ()
  (format t "~A (cl-quil: ~A) [~A]~%" +QUILC-VERSION+ +CL-QUIL-VERSION+ +GIT-HASH+))




(defun entry-point (argv)
  (sb-ext:disable-debugger)
  
  ;; grab the CLI arguments
  (setf *program-name* (pop argv))
  
  (handler-case
      (command-line-arguments:handle-command-line
       *option-spec*
       'process-options
       :command-line argv
       :name "quilc"
       :positional-arity 0
       :rest-arity nil)
    (sb-sys:interactive-interrupt (c)
      (declare (ignore c))
      (format *error-output* "~&! ! ! Caught keyboard interrupt. Exiting.~%")
      (uiop:quit 0))
    (error (c)
      (format *error-output* "~&! ! ! Error: ~A~%" c)
      (uiop:quit 1))))

(defun %entry-point (argv)
  ;; grab the CLI arguments
  (setf *program-name* (pop argv))
  
  (command-line-arguments:handle-command-line
       *option-spec*
       'process-options
       :command-line argv
       :name "quilc"
       :positional-arity 0
       :rest-arity nil))

(defun process-options (&key (compute-gate-depth nil)
                             (compute-gate-volume nil)
                             (compute-runtime nil)
                             (compute-matrix-reps nil)
                             (show-topological-overhead nil)
                             (gate-blacklist nil)
                             (gate-whitelist nil)
                             (without-pretty-printing nil)
                             (verbose nil)
                             (json-serialize nil)
                             (isa nil)
                             (protoquil nil)
                             (version nil)
                             (server-mode nil)
                             (port *server-port*)
                             time-limit
                             (help nil))
  (when help
    (show-help)
    (uiop:quit 0))
  (when version
    (show-version)
    (uiop:quit 0))
  
  (when (plusp time-limit)
    (setf *time-limit* (/ time-limit 1000.0d0)))
  
  (setf *compute-gate-depth* compute-gate-depth)
  (setf *compute-gate-volume* compute-gate-volume)
  (setf *compute-runtime* compute-runtime)
  (setf *compute-matrix-reps* compute-matrix-reps)
  (setf *without-pretty-printing* without-pretty-printing)
  (setf *gate-blacklist* 
        (when gate-blacklist
          (split-sequence:split-sequence #\, (remove #\Space gate-blacklist))))
  (setf *gate-whitelist* 
        (when gate-whitelist
          (split-sequence:split-sequence #\, (remove #\Space gate-whitelist))))
  (setf *topological-swaps* show-topological-overhead)
  (setf *protoquil* protoquil)
  
  ;; at this point we know we're doing something. strap in LAPACK.
  (magicl:with-blapack
    (reload-foreign-libraries)
    
    (cond
      ;; server mode requested
      (server-mode
       ;; null out the streams
       (setf *json-stream* (make-broadcast-stream))
       (setf *human-readable-stream* (make-broadcast-stream))
       (setf *quil-stream* (make-broadcast-stream))
       
       ;; configure the server
       (when port
         (format t "port triggered: ~a.~%" port)
         (setf *server-port* port))
       
       ;; launch the polling loop
       (start-server))
      
      ;; server mode not requested, so continue parsing arguments
      (t
       (cond
         (json-serialize
          (setf *json-stream* *standard-output*)
          (setf *human-readable-stream* (make-broadcast-stream))
          (setf *quil-stream* (make-broadcast-stream)))
         (t
          (setf *json-stream* (make-broadcast-stream))
          (setf *human-readable-stream* *error-output*)
          (setf *quil-stream* *standard-output*)))
       (setf *isa-descriptor*
             (cond
               ((or (null isa)
                    (string= isa "8Q"))
                (quil::build-8Q-chip))
               ((string= isa "20Q")
                (quil::build-skew-rectangular-chip 0 4 5))
               ((string= isa "16QMUX")
                (quil::build-nQ-trivalent-chip 1 1 8 4))
               ((probe-file isa)
                (quil::qpu-hash-table-to-chip-specification
                 (with-open-file (s isa)
                   (yason:parse s))))
               (t
                (error "ISA descriptor does not name a known template or an extant file."))))
       (setf *verbose*
             (cond
               (verbose *human-readable-stream*)
               (t (make-broadcast-stream))))
       (run-CLI-mode)))))

(defun run-CLI-mode ()
  (let* ((program-text (slurp-lines))
         (program (quil::parse-quil program-text)))
    (process-program program *isa-descriptor*)))

(defun process-program (program chip-specification)
  (let* ((original-matrix
           (when (and *protoquil* *compute-matrix-reps*)
             (quil::make-matrix-from-quil (coerce (quil::parsed-program-executable-code program) 'list) program)))
         (quil::*compiler-noise-stream* *verbose*)
         (*statistics-dictionary* (make-hash-table :test 'equal)))
    ;; do the compilation
    (multiple-value-bind (processed-program topological-swaps)
        (quil::compiler-hook program chip-specification :protoquil *protoquil*)
      
      ;; if we're supposed to output protoQuil, we need to strip the final HALT
      ;; instructios from the output
      (when *protoquil*
        (setf (quil::parsed-program-executable-code processed-program)
              (coerce
               (loop :for instr :across (quil::parsed-program-executable-code processed-program)
                     :when (and (typep instr 'quil::pragma-current-rewiring))
                       :do (setf (gethash "final-rewiring" *statistics-dictionary*)
                                 (quil::make-rewiring-from-string (cl-quil::pragma-freeform-string instr)))
                     :unless (typep instr 'quil::halt)
                       :collect instr)
               'vector)))
      
      ;; now that we've compiled the program, we have various things to output
      ;; one thing we're always going to want to output is the program itself.
      (let ((program-as-string
              (with-output-to-string (s)
                (quil::print-parsed-program processed-program s))))
        (setf (gethash "processed_program" *statistics-dictionary*)
              program-as-string)
        (write-string program-as-string *quil-stream*))
      
      
      (when *topological-swaps*
        (print-topological-swap-count topological-swaps))
      
      (when (and *protoquil*
                 (or *compute-gate-depth*
                     *compute-gate-volume*
                     *compute-runtime*))
        ;; calculate some statistics based on logical scheduling
        (let ((lschedule (make-instance 'quil::lscheduler-empty)))
          (loop :for instr :across (quil::parsed-program-executable-code processed-program)
                :when (and (typep instr 'quil::gate-application)
                           (not (member (quil::application-operator instr)
                                        *gate-blacklist*
                                        :test #'string=))
                           (or (null *gate-whitelist*)
                               (member (quil::application-operator instr)
                                       *gate-whitelist*
                                       :test #'string=)))
                  :do (quil::append-instruction-to-lschedule lschedule instr))
          (when *compute-gate-depth*
            (print-gate-depth lschedule))
          (when *compute-gate-volume*
            (print-gate-volume lschedule))
          (when *compute-runtime*
            (print-program-runtime lschedule chip-specification))))
      
      (when (and *protoquil* *compute-matrix-reps*)
        (let ((processed-quil (quil::parsed-program-executable-code processed-program))
              (initial-l2p (quil::make-rewiring-from-string
                            (quil::pragma-freeform-string
                             (aref (quil::parsed-program-executable-code processed-program) 0))))
              (final-l2p (quil::make-rewiring-from-string
                          (quil::pragma-freeform-string
                           (aref (quil::parsed-program-executable-code processed-program)
                                 (1- (length (quil::parsed-program-executable-code processed-program))))))))
          (print-matrix-representations initial-l2p
                                        (coerce processed-quil 'list)
                                        final-l2p
                                        original-matrix)))
      
      (publish-json-statistics))))
