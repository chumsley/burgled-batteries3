(in-package #:python.cffi)

(declaim (optimize (debug 3)))

;;;; FFI Library
;; Much of what we do below requires it be loaded during macroexpansion time.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (define-foreign-library python-library
    (:darwin (:framework "Python"))
    (:unix (:or "libpython2.7.so.1.0" "libpython2.6.so.1.0" "libpython2.5.so.1.0" "libpython2.4.so.1.0" "libpython2.3.so.1.0"))
    (:windows (:or "python27.dll" "python26.dll" "python25.dll" "python24.dll" "python23.dll"))
    (t (:default "libpython")))
  (use-foreign-library python-library))

;;;; Basic Handling of the PyObject struct
(defcstruct %object
  ;; #ifdef Py_TRACE_REFS
  #+pyffi.trace-refs (-ob-next object)
  #+pyffi.trace-refs (-ob-prev object)
  ;; #endif
  (refcnt ssize-t)
  (type :pointer))

(defun %object.refcnt (o) (and (pointerp o) (not (null-pointer-p o)) (foreign-slot-value o '%object 'refcnt)))
(defun %object.type (o) (foreign-slot-value o '%object 'type))
(defun %object.type-check-exact (o type) (pointer-eq (%object.type o) type))

;;;; Functions Related to Embedding CPython
(defpyfun "Py_Initialize"   :void ()
  (:documentation "Initialize the Python interpreter.  This, or .INITIALIZE-EX, must be called before Python may be used."))
(defpyfun "Py_InitializeEx" :void ((initsigs :int))
  (:documentation "Like .INITIALIZE if INITSIGS is 1.  If INITSIGS is 0, skips registration of signal handlers."))
(defpyfun "Py_IsInitialized" :boolean ()
  (:documentation "Returns true if the Python interpreter has been initialize, false otherwise."))

(defpyfun "Py_Finalize" :void ())

(defpyfun "Py_SetProgramName" :void ((name :string)))
(defpyfun "Py_GetProgramName" :string ())
(defpyfun "Py_GetPrefix" :string ())          ; FIXME: directory pathname?
(defpyfun "Py_GetExecPrefix" :string ())      ; FIXME: directory pathname?
(defpyfun "Py_GetProgramFullPath" :string ()) ; FIXME: return a pathname?
(defpyfun "Py_GetPath" :string ())            ; FIXME?: Split on #\: or #\; and return a list of pathnames?
(defpyfun "Py_GetVersion" :string ())
(defpyfun "Py_GetPlatform" :string ())
(defpyfun "Py_GetCopyright" :string ())
(defpyfun "Py_GetCompiler" :string ())
(defpyfun "Py_GetBuildInfo" :string ())
#+requires-CHAR*-ARRAY-support (defpyfun "PySys_SetArgvEx" :void ((argc :int) (argv (:array :string)) (updatepath :int))
                                 (:implementation (sys.set-argv argc argv)))
#+requires-CHAR*-ARRAY-support (defpyfun "PySys_SetArgv" :void ((argc :int) (argv (:array :string))))
(defpyfun "Py_SetPythonHome" :void ((home :string))) ; WARNING: requires static string!
(defpyfun "Py_GetPythonHome" :string ())

;;;; Definitions Relating to Python Types

;;; PyObject is the root of all other types
(defpytype "PyObject"
  (:errorp #'null-pointer-p)
  (:to (value type)
    ;; TODO: Need a way to pick from multiple types.  Because PyBool is a
    ;;       subclass of PyInt, right now which we get depends on the hash
    ;;       order.
    (loop :for v :being :the :hash-values :of *type-map*
          :for foreign-type := (funcall v reference-type)
          :when (funcall (slot-value foreign-type 'lisp-is-type) value)
            :do (return (translate-to-foreign value foreign-type))
          :finally (return value)))
  (:from (value type)
    ;(if (null-pointer-p value) (raise-python-exception))
    (unless (null-pointer-p value)
      ;; NECESSARY!  If we return the pointer, the later .DEC-REF in tff will
      ;; be too early; if we convert to a subtype of PyObject, that conversion
      ;; will also trigger a .DEC-REF, taking us to zero before we're ready.
      (unless (borrowed-reference-p type) (.inc-ref value))
      (loop :for v :being :the :hash-values :of *type-map*
            :for foreign-type := (funcall v reference-type)
            :when (funcall (slot-value foreign-type 'foreign-is-type) value)
              :do (return (translate-from-foreign value foreign-type))
            :finally (return value)))))
(defctype object? (soft-error object))

;; PyType objects have a structure with something we want.  Unfortunately for
;; us, the part we want is a ways into it.
(defcstruct %type
  ;; #ifdef Py_TRACE_REFS
  #+pyffi.trace-refs (-ob-next object)
  #+pyffi.trace-refs (-ob-prev object)
  ;; #endif
  (refcnt ssize-t)
  (type :pointer) (name :pointer)
  (basicsize ssize-t) (itemsize ssize-t)
  ;; standard operations
  (dealloc :pointer) (print   :pointer) (getattr :pointer)
  (setattr :pointer) (compare :pointer) (repr    :pointer)
  ;; generic methods
  (as-number :pointer) (as-sequence :pointer) (as-mapping :pointer)
  ;; more standard ops
  (hash :pointer) (call :pointer) (str :pointer)
  (getattro :pointer) (setattro :pointer)
  ;; as buffer
  (as-buffer :pointer)
  ;; the part we actually care about
  (flags :long)
  ;; docstring
  (doc :pointer)
  ;; mo' functions
  (traverse :pointer) (clear :pointer) (richcompare :pointer)
  ;; weak references
  (weaklistoffset ssize-t)
  ;; iterators
  (iter :pointer) (iternext :pointer))

(defpytype "PyType"
  (:to   (value type) value)
  (:from (value type) value))

;; Docs say use Py_None, but _Py_NoneStruct is what's exported
(defpyvar "_Py_NoneStruct" +None+)
(defun %none.check (o) (pointer-eq +None+ o))

;;; Numeric Types
(defpytype "PyInt"
  (:type integer)
  (:to   (value type) (int.from-long* value))
  (:from (value type) (int.as-long value)))

(defpyvar "_Py_ZeroStruct" +False+)
(defpyvar "_Py_TrueStruct" +True+)
(defpytype "PyBool"
  (:superclass "PyInt")
  (:type boolean)
  (:to (value type) (if value +True+ +False+))
  (:from (value type)
    (cond
      ((pointer-eq +True+ value) t)
      ((pointer-eq +False+ value) nil)
      (t (error "Not a boolean!")))))

(defpytype "PyLong"
  (:to (value type) (long.from-long* value))
  (:from (value type) (long.as-long value)))

(defpytype "PyFloat"
  (:type cl:float)
  (:to   (value type) (float.from-double* value))
  (:from (value type) (float.as-double   value)))

;; FIXME: Actually using %complex will require FSBV integration (coming soon to a CFFI near you!)
(defcstruct %complex (real :double) (imag :double))
(defpytype "PyComplex"
  (:type cl:complex)
  (:errorp #'%error-occurred-p)
  (:to (value type)
    (complex.from-doubles* (realpart value) (imagpart value)))
  (:from (value type)
    (cl:complex (complex.real-as-double value) (complex.imag-as-double value))))

;;; Sequence Types
;; ByteArray is not fundamentally different from String/Bytes, except we don't
;; bother trying to pretend it's got characters at all.
(defpytype "PyByteArray"
  (:type (array (unsigned-byte 8)))
  (:to   (value type) (byte-array.from-string-and-size* value (length value)))
  (:from (value type) (byte-array.as-string value)))

;; WARNING!  PyString conversion will fail when there are disagreements with
;;           encodings, or embedded NULs; and the inability to ask a string what
;;           encoding it is means this isn't really fixable in practice.  If you
;;           want reliable string conversion you should use PyUnicode, and
;;           PyByteArray for reliable octet-array conversion.
(defpytype "PyString"
  (:to   (value type) (string.from-string* value))
  (:from (value type) (string.as-string    value)))

#+(or) ;; FIXME: we'll need the bytes.whatever functions, and a way to alias the
       ;;        PyString bits that make up PyBytes in Python 2
(defpytype "PyBytes"
  (:to   (value type) (bytes.from-string* value))
  (:from (value type) (bytes.as-string    value)))

;; Shorthand types for unicode strings
(defctype utf8-string (:string :encoding :utf-8))
(defctype ucs2-string (:string :encoding #+little-endian :ucs-2/le #+big-endian :ucs-2/be))
(defctype ucs4-string (:string :encoding #+little-endian :ucs-4/le #+big-endian :ucs-4/be))

;; PyUnicode should be preferred to PyString because it avoids the issue of
;; encodings.
(defpytype "PyUnicode"
  (:type cl:string)
  (:to   (value type) (unicode.from-unicode* value (length value)))
  (:from (value type) (unicode.as-unicode value)))

#+(or) ;; Skipping old-style buffers
(defpytype "PyBuffer"
  (:to (value type) …)
  (:from (value type) …))

(defpytype "PyTuple"
  ;; CAUTION: tuple of characters may get confused with strings
  (:type (and vector (not cl:string)))
  (:to (value type)
    (let* ((len (length value))
           (tup (tuple.new* len)))
      (dotimes (i len tup)
        (tuple.set-item tup i (svref value i)))))
  (:from (value type)
    (let* ((len (tuple.size value))
           (tup (make-array len)))
      (dotimes (i len tup)
        (setf (svref tup i) (tuple.get-item value i))))))

(defpytype "PyList"
  (:type cl:list)
  (:to (value type)
    (loop :with list = (list.new* (length value))
          :for item :in value :and i :from 0
          :do (list.set-item list i item))
    #+(or) ;; slow (because of nth)
    (let* ((len (length value))
           (lst (list.new len)))
      (dotimes (i len lst)
        (list.set-item lst i (nth i value)))))
  (:from (value type)
    (loop :for i :from 0 :to (1- (list.size value))
          :collect (list.get-item value i))))

;;; Mapping Types
(defpytype "PyDict"
  (:type hash-table)
  (:to (value type)
    (let ((dict (dict.new*)))
      (maphash (lambda (k v) (dict.set-item dict k v)) value)
      dict))
  (:from (value type)
    ;; Probably premature optimization, but the below avoids the translation
    ;; machinery for the bits we'd just GC anyway
    (let* ((dict (make-hash-table :test #'equal))
           (items (dict.items* value)))
      (unwind-protect
           (dotimes (i (list.size items) dict)
             (let* ((item (list.get-item* items i))
                    (key (tuple.get-item item 0))
                    (value (tuple.get-item item 1)))
               (when (string= key "bozo_exception") (format t "BOZO!  ~A~%" (object.str value)))
               (setf (gethash key dict) value)))
        (.dec-ref items)))))

;;; TODO: Other Objects (Class, Instance, Function, Method, File, Module, Iterator, Descriptor, ...)


;;;; API Functions Relating to Threads, Interpreter State, and Debugging

;;; Threads
(defctype interpreter-state :pointer)
(defctype thread-state :pointer)

(defpyfun "PyEval_InitThreads" :void () (:requires :python-threads))
(defpyfun "PyEval_ThreadsInitialized" :boolean ())
(defpyfun "PyEval_SaveThread" thread-state ())
(defpyfun "PyEval_RestoreThread" :void ((tstate thread-state)))
(defpyfun "PyThreadState_Get" thread-state ())
(defpyfun "PyThreadState_Swap" thread-state ((tstate thread-state)))
(defpyfun "PyEval_ReInitThreads" :void ())
(defcenum (gilstate.state :int) :locked :unlocked)
(defpyfun "PyGILState_Ensure" gilstate.state ())
(defpyfun "PyGILState_Release" :void ((state gilstate.state)))
(defpyfun "PyGILState_GetThisThreadState" thread-state ())

(defmacro with-thread-state (&body body)
  "The Lispy equivalent of surrounding code with Py_BEGIN_ALLOW_THREADS ... Py_END_ALLOW_THREADS."
  (with-unique-names (thread-state)
    `(let ((,thread-state (eval.save-thread)))
       (unwind-protect (progn ,@body)
         (eval.restore-thread ,thread-state)))))

(defpyfun "PyInterpreterState_New" interpreter-state () (:requires :python-threads))
(defpyfun "PyInterpreterState_Clear" :void ((interp interpreter-state)) (:requires :python-threads))
(defpyfun "PyInterpreterState_Delete" :void ((interp interpreter-state)) (:requires :python-threads))
(defpyfun "PyThreadState_New" thread-state ((interp interpreter-state)) (:requires :python-threads))
(defpyfun "PyThreadState_Clear" :void ((tstate thread-state)) (:requires :python-threads))
(defpyfun "PyThreadState_Delete" :void ((tstate thread-state)) (:requires :python-threads))
(defpyfun "PyThreadState_GetDict" (dict :borrowed) () (:requires :python-threads))
(defpyfun "PyThreadState_SetAsyncExc" :int ((id :long) (exc object)) (:requires :python-threads))
(defpyfun "PyEval_AcquireThread" :void ((tstate thread-state)) (:requires :python-threads))
(defpyfun "PyEval_ReleaseThread" :void ((tstate thread-state)) (:requires :python-threads))
(defpyfun "PyEval_AcquireLock" :void () (:requires :python-threads))
(defpyfun "PyEval_ReleaseLock" :void () (:requires :python-threads))

;;; Sub-Interpreters
(defpyfun "Py_NewInterpreter" thread-state ())
(defpyfun "Py_EndInterpreter" :void ((tstate thread-state)))

;;; Async Notifications
;; TODO: Add define-notification-callback macro like define-trace-function below?
(defpyfun "Py_AddPendingCall" 0-on-success ((callback :pointer) (arg :pointer))
  (:requires "Python 2.7 (or newer)"))

;;; Profiling and Tracing
(defctype frame-object :pointer)
(defctype .tracefunc :pointer)
;; FIXME: should we call this define-trace-callback instead?  define-trace-function-callback?
(defmacro define-trace-function (name (object frame what arg) &body body)
  `(defcallback ,name :int ((,object object) (,frame frame-object) (,what :int) (,arg object))
     ,@body))

(defpyfun "PyEval_SetProfile" :void ((func .tracefunc) (obj object)))
(defpyfun "PyEval_SetTrace" :void ((func .tracefunc) (obj object)))
(defpyfun "PyEval_GetCallStats" object ((self object)) (:requires :python-call-profile))
(defconstant +pcall-all+             0) ; Are these really necessary, or should
(defconstant +pcall-function+        1) ; we instead split out the tuple into
(defconstant +pcall-fast-function+   2) ; something like an alist or a
(defconstant +pcall-faster-function+ 3) ; call-stats struct?
(defconstant +pcall-method+          4)
(defconstant +pcall-bound-method+    5)
(defconstant +pcall-cfunction+       6)
(defconstant +pcall-type+            7)
(defconstant +pcall-generator+       8)
(defconstant +pcall-other+           9)
(defconstant +pcall-pop+            10)

;;; Advanced Debugger Support
(defpyfun "PyInterpreterState_Head" interpreter-state ())
(defpyfun "PyInterpreterState_Next" interpreter-state ((interp interpreter-state)))
(defpyfun "PyInterpreterState_ThreadHead" thread-state ((interp interpreter-state)))
(defpyfun "PyThreadState_Next" thread-state ((tstate thread-state)))

;;;; High-level Interpreter Functions
(defcstruct compiler-flags (flags :int))
#+requires-CHAR*-ARRAY-support (defpyfun "Py_Main" :int ((argc :int) (argv (:array :string)))) ;canerr
#+requires-FILE*-support (defpyfun "PyRun_AnyFile"        0-on-success/no-fetch ((fp :file) (filename :string)))
#+requires-FILE*-support (defpyfun "PyRun_AnyFileFlags"   0-on-success/no-fetch ((fp :file) (filename :string) (flags compiler-flags)))
#+requires-FILE*-support (defpyfun "PyRun_AnyFileEx"      0-on-success/no-fetch ((fp :file) (filename :string) (closeit :int)))
#+requires-FILE*-support (defpyfun "PyRun_AnyFileExFlags" 0-on-success/no-fetch ((fp :file) (filename :string) (closeit :int) (flags compiler-flags)))
(defpyfun "PyRun_SimpleString"      0-on-success/no-fetch ((command :string)))
(defpyfun "PyRun_SimpleStringFlags" 0-on-success/no-fetch ((command :string) (flags compiler-flags)))
#+requires-FILE*-support (defpyfun "PyRun_SimpleFile"        0-on-success/no-fetch ((fp :file) (filename :string)))
#+requires-FILE*-support (defpyfun "PyRun_SimpleFileFlags"   0-on-success/no-fetch ((fp :file) (filename :string) (flags compiler-flags)))
#+requires-FILE*-support (defpyfun "PyRun_SimpleFileEx"      0-on-success/no-fetch ((fp :file) (filename :string) (closeit :int)))
#+requires-FILE*-support (defpyfun "PyRun_SimpleFileExFlags" 0-on-success/no-fetch ((fp :file) (filename :string) (closeit :int) (flags compiler-flags)))
;; FIXME: The Python docs leave me uncertain as to whether these are /no-fetch
#+requires-FILE*-support (defpyfun "PyRun_InteractiveOne"       0-on-success ((fp :file) (filename :string)))
#+requires-FILE*-support (defpyfun "PyRun_InteractiveOneFlags"  0-on-success ((fp :file) (filename :string) (flags compiler-flags)))
#+requires-FILE*-support (defpyfun "PyRun_InteractiveLoop"      0-on-success ((fp :file) (filename :string)))
#+requires-FILE*-support (defpyfun "PyRun_InteractiveLoopFlags" 0-on-success ((fp :file) (filename :string) (flags compiler-flags)))

(defctype .node (can-error :pointer))
(defpyfun "PyParser_SimpleParseString"              .node ((str :string) (start :int)))
(defpyfun "PyParser_SimpleParseStringFlags"         .node ((str :string) (start :int) (flags :int)))
(defpyfun "PyParser_SimpleParseStringFlagsFilename" .node ((str :string) (filename :string) (start :int) (flags :int)))
#+requires-FILE*-support (defpyfun "PyParser_SimpleParseFile"      .node ((fp :file) (filename :string) (start :int)))
#+requires-FILE*-support (defpyfun "PyParser_SimpleParseFileFlags" .node ((fp :file) (filename :string) (start :int) (flags :int)))

(defpyfun "PyRun_String"      object! ((str :string) (start :int) (globals dict) (locals dict)))
(defpyfun "PyRun_StringFlags" object! ((str :string) (start :int) (globals dict) (locals dict) (flags compiler-flags)))
#+requires-FILE*-support (defpyfun "PyRun_File"        object! ((fp :file) (filename :string) (start :int) (globals dict) (locals dict)))
#+requires-FILE*-support (defpyfun "PyRun_FileEx"      object! ((fp :file) (filename :string) (start :int) (globals dict) (locals dict) (closeit :int)))
#+requires-FILE*-support (defpyfun "PyRun_FileFlags"   object! ((fp :file) (filename :string) (start :int) (globals dict) (locals dict) (flags compiler-flags)))
#+requires-FILE*-support (defpyfun "PyRun_FileExFlags" object! ((fp :file) (filename :string) (start :int) (globals dict) (locals dict) (closeit :int) (flags compiler-flags)))

(defctype code-object :pointer)
(defpyfun "Py_CompileString"      (can-error code-object) ((str :string) (filename :string) (start :int)))
(defpyfun "Py_CompileStringFlags" (can-error code-object) ((str :string) (filename :string) (start :int) (flags compiler-flags)))
(defpyfun "PyEval_EvalCode"    object! ((co code-object) (globals dict) (locals dict)))
#+requires-POINTER-ARRAY-support (defpyfun "PyEval_EvalCodeEx"  object! ((co code-object) (globals dict) (locals dict) (args (:array object)) (argcount :int) (kws (:array object)) (kwcount :int) (defs (:array object)) (defcount :int) (closure object)))
(defpyfun "PyEval_EvalFrame"   object! ((f frame-object)))
(defpyfun "PyEval_EvalFrameEx" object! ((f frame-object) (throwflag :int)))
(defpyfun "PyEval_MergeCompilerFlags" :boolean ((cf compiler-flags)))

;;;; Memory Management
;; These take pointers, rather than objects, because converting an object to
;; pass into these functions would be nonsensical.
(defpyfun "Py_IncRef" :void ((o :pointer)))
(defpyfun "Py_DecRef" :void ((o :pointer)))

;;;; Error Handling

;;; Python Error API
(defctype always-error object!)
(defpyfun "PyErr_PrintEx" :void ((set-sys-last-vars :int)))
(defpyfun "PyErr_Print"   :void ())
(defpyfun "PyErr_Occurred" (object :borrowed) ())
(defpyfun "PyErr_ExceptionMatches"      :boolean ((exc object)))
(defpyfun "PyErr_GivenExceptionMatches" :boolean ((given object) (exc object)))
#+requires-call-by-reference-support (defpyfun "PyErr_NormalizeException" :void ((exc (:ref object)) (val (:ref object)) (tb (:ref object))))
(defpyfun "PyErr_Clear" :void ())
#+requires-call-by-reference-support (defpyfun "PyErr_Fetch" :void ((ptype (:ref object)) (pvalue (:ref object)) (ptraceback (:ref object))))
(defpyfun "PyErr_Restore" :void ((type object) (value object) (traceback object)))
(defpyfun "PyErr_SetString" :void ((type object) (message :string)))
(defpyfun "PyErr_SetObject" :void ((type object) (value object)))
(defpyfun "PyErr_Format" always-error ((exception object) (format :string) &rest))
(defpyfun "PyErr_SetNone" :void ((type object)))
(defpyfun "PyErr_BadArgument" :int ())
(defpyfun "PyErr_NoMemory" always-error ())
(defpyfun "PyErr_SetFromErrno"             always-error ((type object)))
(defpyfun "PyErr_SetFromErrnoWithFilename" always-error ((type object) (filename :string)))
(defpyfun "PyErr_SetFromWindowsErr"                always-error ((ierr :int)) (:requires :windows))
(defpyfun "PyErr_SetExcFromWindowsErr"             always-error ((type object) (ierr :int)) (:requires :windows))
(defpyfun "PyErr_SetFromWindowsErrWithFilename"    always-error ((ierr :int) (filename :string)) (:requires :windows))
(defpyfun "PyErr_SetExcFromWindowsErrWithFilename" always-error ((type object) (ierr :int) (filename :string)) (:requires :windows))
(defpyfun "PyErr_BadInternalCall" :void ())
(defpyfun "PyErr_WarnEx" 0-on-success ((category object) (message :string) (stacklevel :int)))
(defpyfun "PyErr_Warn"   0-on-success ((category object) (message :string)))
(defpyfun "PyErr_WarnExplicit" :int ((category object) (message :string) (filename :string) (lineno :int) (module :string) (registry object))) ; FIXME: what's the return value mean?
(defcvar ("Py_Py3kWarningFlag" *err.warn-py3k*) :boolean)
(defpyvar "PyExc_DeprecationWarning")
(defpyfun "PyErr_WarnPy3k" 0-on-success ((message :string) (stacklevel :int))
  (:implementation
   (if *err.warn-py3k* (err.warn-ex +exc.deprecation-warning+ message stacklevel) 0)))
(defpyfun "PyErr_CheckSignals" 0-on-success ())
(defpyfun "PyErr_SetInterrupt" :void ())
(defpyfun "PySignal_SetWakeupFd" :int ((fd :int)) (:requires "Python 2.6 (or newer)")) ; FIXME: return value means...?
(defpyfun "PyErr_NewException"        object ((name :string) (base object) (dict dict)))
(defpyfun "PyErr_NewExceptionWithDoc" object ((name :string) (doc :string) (base object) (dict dict))
  (:implementation
   (declare (ignore doc))
   (err.new-exception* name base dict)))
(defpyfun "PyErr_WriteUnraisable" :void ((obj object)))

;;; Unicode Exceptions
(defpyfun "PyUnicodeDecodeError_Create" object ((encoding :string) (object :string) (length ssize-t) (start ssize-t) (end ssize-t) (reason :string)))
(defpyfun "PyUnicodeEncodeError_Create" object ((encoding :string) (object unicode) (length ssize-t) (start ssize-t) (end ssize-t) (reason :string)))
(defpyfun "PyUnicodeTranslateError_Create" object ((object unicode) (length ssize-t) (start ssize-t) (end ssize-t) (reason :string)))
(defpyfun "PyUnicodeDecodeError_GetEncoding" object ((exc object)))
(defpyfun "PyUnicodeEncodeError_GetEncoding" object ((exc object)))
(defpyfun "PyUnicodeDecodeError_GetObject"    object ((exc object)))
(defpyfun "PyUnicodeEncodeError_GetObject"    object ((exc object)))
(defpyfun "PyUnicodeTranslateError_GetObject" object ((exc object)))
#+requires-call-by-reference-support (defpyfun "PyUnicodeDecodeError_GetStart"    0-on-success ((exc object) (start (:pointer ssize-t))))
#+requires-call-by-reference-support (defpyfun "PyUnicodeEncodeError_GetStart"    0-on-success ((exc object) (start (:pointer ssize-t))))
#+requires-call-by-reference-support (defpyfun "PyUnicodeTranslateError_GetStart" 0-on-success ((exc object) (start (:pointer ssize-t))))
(defpyfun "PyUnicodeDecodeError_SetStart"    0-on-success ((exc object) (start ssize-t)))
(defpyfun "PyUnicodeEncodeError_SetStart"    0-on-success ((exc object) (start ssize-t)))
(defpyfun "PyUnicodeTranslateError_SetStart" 0-on-success ((exc object) (start ssize-t)))
#+requires-call-by-reference-support (defpyfun "PyUnicodeDecodeError_GetEnd"    0-on-success ((exc object) (end (:pointer ssize-t))))
#+requires-call-by-reference-support (defpyfun "PyUnicodeEncodeError_GetEnd"    0-on-success ((exc object) (end (:pointer ssize-t))))
#+requires-call-by-reference-support (defpyfun "PyUnicodeTranslateError_GetEnd" 0-on-success ((exc object) (end (:pointer ssize-t))))
(defpyfun "PyUnicodeDecodeError_SetEnd"    0-on-success ((exc object) (end ssize-t)))
(defpyfun "PyUnicodeEncodeError_SetEnd"    0-on-success ((exc object) (end ssize-t)))
(defpyfun "PyUnicodeTranslateError_SetEnd" 0-on-success ((exc object) (end ssize-t)))
(defpyfun "PyUnicodeDecodeError_GetReason"    object ((exc object)))
(defpyfun "PyUnicodeEncodeError_GetReason"    object ((exc object)))
(defpyfun "PyUnicodeTranslateError_GetReason" object ((exc object)))
(defpyfun "PyUnicodeDecodeError_SetReason"    0-on-success ((exc object) (reason :string)))
(defpyfun "PyUnicodeEncodeError_SetReason"    0-on-success ((exc object) (reason :string)))
(defpyfun "PyUnicodeTranslateError_SetReason" 0-on-success ((exc object) (reason :string)))
;; TODO: Probably just have a with-recursive-call macro, instead of these
;;       functions.  Of course, they'd still need to be defined for the
;;       macro's use.
#+really-a-#define (defpyfun "Py_EnterRecursiveCall" 0-on-success ((where :string)))
#+really-a-#define (defpyfun "Py_LeaveRecursiveCall" :void ())

;;; Exception Variables
(defpyvar "PyExc_BaseException")
(defpyvar "PyExc_Exception")
(defpyvar "PyExc_StandardError")
(defpyvar "PyExc_ArithmeticError")
(defpyvar "PyExc_LookupError")
(defpyvar "PyExc_AssertionError")
(defpyvar "PyExc_AttributeError")
(defpyvar "PyExc_EOFError")
(defpyvar "PyExc_EnvironmentError")
(defpyvar "PyExc_FloatingPointError")
(defpyvar "PyExc_IOError")
(defpyvar "PyExc_ImportError")
(defpyvar "PyExc_IndexError")
(defpyvar "PyExc_KeyError")
(defpyvar "PyExc_KeyboardInterrupt")
(defpyvar "PyExc_MemoryError")
(defpyvar "PyExc_NameError")
(defpyvar "PyExc_NotImplementedError")
(defpyvar "PyExc_OSError")
(defpyvar "PyExc_OverflowError")
(defpyvar "PyExc_ReferenceError")
(defpyvar "PyExc_RuntimeError")
(defpyvar "PyExc_SyntaxError")
(defpyvar "PyExc_SystemError")
(defpyvar "PyExc_SystemExit")
(defpyvar "PyExc_TypeError")
(defpyvar "PyExc_ValueError")
#+windows (defpyvar "PyExc_WindowsError")
(defpyvar "PyExc_ZeroDivisionError")

;;;; TODO: Operating System Utilities, System Functions, Process Control
;;;; TODO: Check Importing Modules; ensure all functions accounted for
;;;; TODO: Data Marshalling Support
;;;; TODO: Passing Arguments and Building Values
;;;; TODO: String Conversion and Formatting
;;;; TODO: Reflection
;;;; TODO: Codec Registry and Support Functions, Codec Lookup API, Registry API for Unicode Errors

;;;; Abstract Objects

;;; Object Protocol
#+requires-FILE*-support (defpyfun "PyObject_Print" :int ((o object) (fp :file) (flags :int)))
(defpyfun "PyObject_HasAttr"       :boolean ((o object) (attr-name object)))
(defpyfun "PyObject_HasAttrString" :boolean ((o object) (attr-name :string)))
(defpyfun "PyObject_GetAttr"        object! ((o object) (attr-name object)))
(defpyfun "PyObject_GetAttrString"  object! ((o object) (attr-name :string)))
(defpyfun "PyObject_GenericGetAttr" object! ((o object) (name object))) ; FIXME: docs don't specify canerr or new/borrowed
(defpyfun "PyObject_SetAttr"        0-on-success ((o object) (attr-name object)  (v object)))
(defpyfun "PyObject_SetAttrString"  0-on-success ((o object) (attr-name :string) (v object)))
(defpyfun "PyObject_GenericSetAttr" 0-on-success ((o object) (name object) (value object)))
(defpyfun "PyObject_DelAttr" 0-on-success ((o object) (attr-name object))
  (:implementation (object.set-attr o attr-name (null-pointer))))
(defpyfun "PyObject_DelAttrString" 0-on-success ((o object) (attr-name :string))
  (:implementation (object.set-attr-string o attr-name (null-pointer))))
(defpyfun "PyObject_RichCompare"     object! ((o1 object) (o2 object) (opid :int)))
(defpyfun "PyObject_RichCompareBool" boolean! ((o1 object) (o2 object) (opid :int)))
#+requires-call-by-reference-support (defpyfun "PyObject_Cmp" boolean! ((o1 object) (o2 object) (result (:ref :int))))
(defpyfun "PyObject_Compare" boolean! ((o1 object) (o2 object)))
(defpyfun "PyObject_Repr" object! ((o object)))
(defpyfun "PyObject_Str"  object! ((o object)))
(defpyfun "PyObject_Bytes" object! ((o object))
  (:implementation (object.str* o)))
(defpyfun "PyObject_Unicode" object! ((o object)))
(defpyfun "PyObject_IsInstance" boolean! ((inst    object) (cls object)))
(defpyfun "PyObject_IsSubclass" boolean! ((derived object) (cls object)))
(defpyfun "PyCallable_Check" :boolean ((o object)))
(defpyfun "PyObject_Call"         object! ((callable-object object) (args object) (kw object)))
(defpyfun "PyObject_CallObject"   object! ((callable-object object) (args object)))
;; FIXME: how do we get conversion for &rest arguments?
(defpyfun "PyObject_CallFunction" object! ((callable object) (format :string) &rest))
(defpyfun "PyObject_CallMethod"   object! ((o object) (method :string) (format :string) &rest))
#+requires-arg-after-&rest (defpyfun "PyObject_CallFunctionObjArgs" object! ((callable object) &rest #+(or) <NULL>))
#+requires-arg-after-&rest (defpyfun "PyObject_CallMethodObjArgs"   object! ((o object) (name object) &rest #+(or) <NULL>))
(defpyfun "PyObject_Hash" (can-error :long) ((o object)))
(defpyfun "PyObject_HashNotImplemented" (can-error :long) ((o object)))
(defpyfun "PyObject_IsTrue" boolean! ((o object)))
(defpyfun "PyObject_Not"    boolean! ((o object)))
(defpyfun "PyObject_Type" object! ((o object)))
(defpyfun "PyObject_TypeCheck" :boolean ((o object) (type type))
  (:implementation (if (or (%object.type-check-exact o type)
                           (type.is-subtype (%object.type o) type))
                       1 0)))
(defpyfun "PyObject_Length" ssize-t! ((o object)))
(defpyfun "PyObject_Size"   ssize-t! ((o object)))
(defpyfun "PyObject_GetItem" object! ((o object) (key object)))
(defpyfun "PyObject_SetItem" 0-on-success ((o object) (key object) (v object)))
(defpyfun "PyObject_DelItem" 0-on-success ((o object) (key object)))
(defpyfun "PyObject_DelItemString" 0-on-success ((o object) (key :string)))
(defpyfun "PyObject_AsFileDescriptor" (can-error :int) ((o object)))
(defpyfun "PyObject_Dir" list! ((o object)))
(defpyfun "PyObject_GetIter" object! ((o object)))

;;; Number Protocol
(defpyfun "PyNumber_Check" :boolean ((o object)))
(defpyfun "PyNumber_Add"         object! ((o1 object) (o2 object)))
(defpyfun "PyNumber_Subtract"    object! ((o1 object) (o2 object)))
(defpyfun "PyNumber_Multiply"    object! ((o1 object) (o2 object)))
(defpyfun "PyNumber_Divide"      object! ((o1 object) (o2 object)))
(defpyfun "PyNumber_FloorDivide" object! ((o1 object) (o2 object)))
(defpyfun "PyNumber_TrueDivide"  object! ((o1 object) (o2 object)))
(defpyfun "PyNumber_Remainder"   object! ((o1 object) (o2 object)))
(defpyfun "PyNumber_Divmod"      object! ((o1 object) (o2 object)))
(defpyfun "PyNumber_Power"       object! ((o1 object) (o2 object) (o3 object))) ; o3 optional; but must pass Py_None, not NULL
(defpyfun "PyNumber_Negative"    object! ((o object)))
(defpyfun "PyNumber_Positive"    object! ((o object)))
(defpyfun "PyNumber_Absolute"    object! ((o object)))
(defpyfun "PyNumber_Invert"      object! ((o object)))
(defpyfun "PyNumber_Lshift"      object! ((o1 object) (o2 object)))
(defpyfun "PyNumber_Rshift"      object! ((o1 object) (o2 object)))
(defpyfun "PyNumber_And"         object! ((o1 object) (o2 object)))
(defpyfun "PyNumber_Xor"         object! ((o1 object) (o2 object)))
(defpyfun "PyNumber_Or"          object! ((o1 object) (o2 object)))
(defpyfun "PyNumber_InPlaceAdd"         object! ((o1 object) (o2 object)))
(defpyfun "PyNumber_InPlaceSubtract"    object! ((o1 object) (o2 object)))
(defpyfun "PyNumber_InPlaceMultiply"    object! ((o1 object) (o2 object)))
(defpyfun "PyNumber_InPlaceDivide"      object! ((o1 object) (o2 object)))
(defpyfun "PyNumber_InPlaceFloorDivide" object! ((o1 object) (o2 object)))
(defpyfun "PyNumber_InPlaceTrueDivide"  object! ((o1 object) (o2 object)))
(defpyfun "PyNumber_InPlaceRemainder"   object! ((o1 object) (o2 object)))
(defpyfun "PyNumber_InPlacePower"       object! ((o1 object) (o2 object) (o3 object))) ; o3 optional; pass Py_None not NULL
(defpyfun "PyNumber_InPlaceLshift"      object! ((o1 object) (o2 object)))
(defpyfun "PyNumber_InPlaceRshift"      object! ((o1 object) (o2 object)))
(defpyfun "PyNumber_InPlaceAnd"         object! ((o1 object) (o2 object)))
(defpyfun "PyNumber_InPlaceXor"         object! ((o1 object) (o2 object)))
(defpyfun "PyNumber_InPlaceOr"          object! ((o1 object) (o2 object)))
#+requires-call-by-reference-support (defpyfun "PyNumber_Coerce"   0-on-success ((p1 (:ref object)) (p2 (:ref object))))
#+requires-call-by-reference-support (defpyfun "PyNumber_CoerceEx" 0-on-success ((p1 (:ref object)) (p2 (:ref object))))
(defpyfun "PyNumber_Int"    object! ((o object)))
(defpyfun "PyNumber_Long"   object! ((o object)))
(defpyfun "PyNumber_Float"  object! ((o object)))
(defpyfun "PyNumber_Index"  object! ((o object)))
(defpyfun "PyNumber_ToBase" object! ((n object) (base :int)))
(defpyfun "PyNumber_AsSsize_t" ssize-t ((o object) (exc object)))
(defpyfun "PyIndex_Check" :boolean ((o object))
  (:implementation (if (number.check o) 1 0)))

;;; Sequence Protocol
(defpyfun "PySequence_Check" :boolean ((o object)))
(defpyfun "PySequence_Size"   ssize-t! ((o object)))
(defpyfun "PySequence_Length" ssize-t! ((o object)))
(defpyfun "PySequence_Concat" object! ((o1 object) (o2 object)))
(defpyfun "PySequence_Repeat" object! ((o object) (count ssize-t)))
(defpyfun "PySequence_InPlaceConcat" object! ((o1 object) (o2 object)))
(defpyfun "PySequence_InPlaceRepeat" object! ((o object) (count ssize-t)))
(defpyfun "PySequence_GetItem"  object! ((o object) (i ssize-t)))
(defpyfun "PySequence_GetSlice" object! ((o object) (i1 ssize-t) (i2 ssize-t)))
(defpyfun "PySequence_SetItem" 0-on-success ((o object) (i ssize-t) (v object)))
(defpyfun "PySequence_DelItem" 0-on-success ((o object) (i ssize-t)))
(defpyfun "PySequence_SetSlice" 0-on-success ((o object) (i1 ssize-t) (i2 ssize-t) (v object)))
(defpyfun "PySequence_DelSlice" 0-on-success ((o object) (i1 ssize-t) (i2 ssize-t)))
(defpyfun "PySequence_Count"    ssize-t! ((o object) (value object)))
(defpyfun "PySequence_Contains" boolean! ((o object) (value object)))
(defpyfun "PySequence_Index" ssize-t! ((o object) (value object)))
(defpyfun "PySequence_List"  object! ((o object)))
(defpyfun "PySequence_Tuple" object! ((o object)))
(defpyfun "PySequence_Fast"  object! ((o object) (m :string)))
(defpyfun "PySequence_Fast_GET_ITEM" object! ((o object) (i ssize-t))
  (:implementation (cond ((list.check  o) (list.get-item*  o i))
                         ((tuple.check o) (tuple.get-item* o i))
                         (t (sequence.get-item* o i)))))
#+requires-POINTER-ARRAY-support (defpyfun "PySequence_Fast_ITEMS" (:array object) ((o object)))
(defpyfun "PySequence_ITEM" object! ((o object) (i ssize-t))
  (:implementation (sequence.get-item* o i)))
(defpyfun "PySequence_Fast_GET_SIZE" ssize-t! ((o object))
  (:implementation (cond ((list.check o)  (list.size  o))
                         ((tuple.check o) (tuple.size o))
                         (t (sequence.size o)))))

;;; Mapping Protocol
(defpyfun "PyMapping_Check"  :boolean ((o object)))
(defpyfun "PyMapping_Size"   ssize-t! ((o object)))
(defpyfun "PyMapping_Length" ssize-t! ((o object)))
(defpyfun "PyMapping_DelItemString" 0-on-success ((o object) (key :string))
  (:implementation (object.del-item-string o key)))
(defpyfun "PyMapping_DelItem"       0-on-success ((o object) (key object))
  (:implementation (object.del-item o key)))
(defpyfun "PyMapping_HasKeyString" :boolean ((o object) (key :string)))
(defpyfun "PyMapping_HasKey"       :boolean ((o object) (key object)))
(defpyfun "PyMapping_Keys"   list! ((o object))
  (:implementation (object.call-method* o "keys"   (null-pointer))))
(defpyfun "PyMapping_Values" list! ((o object))
  (:implementation (object.call-method* o "values" (null-pointer))))
(defpyfun "PyMapping_Items"  list! ((o object))
  (:implementation (object.call-method* o "items"  (null-pointer))))
(defpyfun "PyMapping_GetItemString" object!      ((o object) (key :string)))
(defpyfun "PyMapping_SetItemString" 0-on-success ((o object) (key :string) (v object)))

;;; Iterator Protocol
(defpyfun "PyIter_Check" :boolean ((o object))
  (:implementation
   (let ((otype (foreign-slot-value o '%object 'type)))
     (if (and (type.has-feature otype +tpflags.have-iter+)
              (not (null-pointer-p (foreign-slot-value o '%type 'iternext))))
         1 0))))
(defpyfun "PyIter_Next"  object?  ((o object)))

;;; Old Buffer Protocol (Skipped)

;;;; Concrete Objects

;;;; Fundamental Objects
;;; Type Objects
(defpyfun "PyType_ClearCache" :uint ())
(defpyfun "PyType_Modified" :void ((type type)))
(defpyfun "PyType_HasFeature" :boolean ((o object) (feature :int))
  (:implementation (logand feature (foreign-slot-value o '%type 'flags))))
(defpyfun "PyType_IS_GC"      :boolean ((o object))
  (:implementation (if (type.has-feature o +tpflags.have-gc+) 1 0)))
(defpyfun "PyType_IsSubtype"  :boolean ((a type) (b type)))
(defpyfun "PyType_GenericAlloc" object! ((type type) (nitems ssize-t)))
(defpyfun "PyType_GenericNew"   object! ((type type) (args object) (kwds object)))
(defpyfun "PyType_Ready"   0-on-success ((type type)))

;;; The None Object
;;; (no functions)

;;;; Numeric Objects
;;; Plain Integer Objects
#+requires-call-by-reference-support (defpyfun "PyInt_FromString"  object! ((str :string) (pend (:ref :string)) (base :int)))
(defpyfun "PyInt_FromLong"    int! ((ival :long)))
(defpyfun "PyInt_FromSsize_t" int! ((ival ssize-t)))
(defpyfun "PyInt_FromSize_t"  int! ((ival size-t)))
(defpyfun "PyInt_AsLong"  :long ((io object)))
(defpyfun "PyInt_AsUnsignedLongMask"     :ulong              ((io object)))
(defpyfun "PyInt_AsUnsignedLongLongMask" :unsigned-long-long ((io object)))
(defpyfun "PyInt_AsSsize_t"              ssize-t             ((io object)))
(defpyfun "PyInt_GetMax" :long ())
(defpyfun "PyInt_ClearFreeList" :int ())

;;; Boolean Objects
(defpyfun "PyBool_FromLong" bool! ((v :long)))

;;; Long Integer Objects
(defpyfun "PyLong_FromLong"             long! ((v :long)))
(defpyfun "PyLong_FromUnsignedLong"     long! ((v :ulong)))
(defpyfun "PyLong_FromSsize_t"          long! ((v ssize-t)))
(defpyfun "PyLong_FromSize_t"           long! ((v size-t)))
(defpyfun "PyLong_FromLongLong"         long! ((v :long-long)))
(defpyfun "PyLong_FromUnsignedLongLong" long! ((v :unsigned-long-long)))
(defpyfun "PyLong_FromDouble"           long! ((v :double)))
#+requires-call-by-reference-support (defpyfun "PyLong_FromString"           long! ((str :string) (pend (:ref :string)) (base :int)))
(defpyfun "PyLong_FromUnicode"          long! ((u unicode) (length ssize-t) (base :int)))
#+requires-VOID*-support (defpyfun "PyLong_FromVoidPtr"          long! ((p (:pointer :void))))
(defpyfun "PyLong_AsLong"                 (soft-error :long)               ((pylong object)))
#+requires-call-by-reference-support (defpyfun "PyLong_AsLongAndOverflow"      (soft-error :long)               ((pylong object) (overflow (:pointer :int))))
#+requires-call-by-reference-support (defpyfun "PyLong_AsLongLongAndOverflow"  (soft-error :long-long)          ((pylong object) (overflow (:pointer :int))))
(defpyfun "PyLong_AsSsize_t"              (soft-error ssize-t)             ((pylong object)))
(defpyfun "PyLong_AsUnsignedLong"         (soft-error :ulong)              ((pylong object)))
(defpyfun "PyLong_AsLongLong"             (soft-error :long-long)          ((pylong object)))
(defpyfun "PyLong_AsUnsignedLongLong"     (soft-error :unsigned-long-long) ((pylong object)))
(defpyfun "PyLong_AsUnsignedLongMask"     :ulong                           ((io object)))
(defpyfun "PyLong_AsUnsignedLongLongMask" :unsigned-long-long              ((io object)))
(defpyfun "PyLong_AsDouble"               (soft-error :double)             ((pylong object)))
#+requires-VOID*-support (defpyfun "PyLong_AsVoidPtr"              (can-error (:pointer :void))     ((pylong object)))

;;; Floating Point Objects
#+requires-call-by-reference-support (defpyfun "PyFloat_FromString" object! ((str object) (pend (:ref :string))))
(defpyfun "PyFloat_FromDouble" float! ((v :double)))
(defpyfun "PyFloat_AsDouble" (soft-error :double) ((pyfloat object)))
(defpyfun "PyFloat_GetInfo" object! ())
(defpyfun "PyFloat_GetMax" :double ())
(defpyfun "PyFloat_GetMin" :double ())
(defpyfun "PyFloat_ClearFreeList" :int ())

;;; Complex Number Objects
#+requires-FSBV-support (defpyfun "_Py_c_sum"  %complex ((left %complex) (right %complex)))
#+requires-FSBV-support (defpyfun "_Py_c_diff" %complex ((left %complex) (right %complex)))
#+requires-FSBV-support (defpyfun "_Py_c_neg"  %complex ((complex %complex)))
#+requires-FSBV-support (defpyfun "_Py_c_prod" %complex ((left %complex) (right %complex)))
#+requires-FSBV-support (defpyfun "_Py_c_quot" %complex ((dividend %complex) (divisor %complex)))
#+requires-FSBV-support (defpyfun "_Py_c_pow"  %complex ((num %complex) (exp %complex)))
#+requires-FSBV-support (defpyfun "PyComplex_FromCComplex" object! ((v %complex)))
(defpyfun "PyComplex_FromDoubles" complex! ((real :double) (imag :double)))
(defpyfun "PyComplex_RealAsDouble" (soft-error :double) ((op object)))
(defpyfun "PyComplex_ImagAsDouble" (soft-error :double) ((op object)))
#+requires-FSBV-support (defpyfun "PyComplex_AsCComplex" (soft-error %complex!) ((op object)))

;;;; Sequence Objects
;;; Byte Array Objects
(defpyfun "PyByteArray_FromObject"        byte-array! ((o object)))
(defpyfun "PyByteArray_FromStringAndSize" byte-array! ((string octet-array) (len ssize-t)))
(defpyfun "PyByteArray_Concat" byte-array! ((a object) (b object)))
(defpyfun "PyByteArray_Size" ssize-t ((bytearray object)))
(defpyfun ("PyByteArray_AsString" %byte-array.as-string) octet-array ((bytearray object)))
(defpyfun "PyByteArray_Resize" :int ((bytearray object) (len ssize-t)))

;; We need the size to correctly convert a Python byte-array to a lisp array,
;; but can't get at it directly from within translate-from-foreign.
(defun byte-array.as-string (bytearray)
  (let ((*byte-array.size* (byte-array.size bytearray)))
    (declare (special *byte-array.size*))
    (%byte-array.as-string bytearray)))
(eval-when (:compile-toplevel :load-toplevel :execute)
  (export 'byte-array.as-string))

;;; String/Bytes Objects
(defpyfun "PyString_FromString"        string! ((v :string)))
(defpyfun "PyString_FromStringAndSize" string! ((v :string) (len ssize-t))) ; size is BYTES, not characters!
(defpyfun "PyString_FromFormat"        string! ((format :string) &rest))
#+requires-va_list-support (defpyfun "PyString_FromFormatV"       string! ((format :string) (vargs va_list)))
(defpyfun "PyString_Size" ssize-t! ((string object)))
(defpyfun "PyString_AsString" :string ((string object)))
#+requires-call-by-reference-support (defpyfun "PyString_AsStringAndSize" 0-on-success ((obj object) (buffer (:ref :string)) (length (:pointer ssize-t))))
#+requires-call-by-reference-support (defpyfun "PyString_Concat"       :void ((string (:ref object)) (newpart object)))
#+requires-call-by-reference-support (defpyfun "PyString_ConcatAndDel" :void ((string (:ref object)) (newpart object)))
#+requires-call-by-reference-support (defpyfun "_PyString_Resize" 0-on-success ((string (:ref object)) (newsize ssize-t)))
(defpyfun "PyString_Format" string! ((format object) (args tuple)))
;; Not in Python 3
;#+requires-call-by-reference-support (defpyfun "PyString_InternInPlace" :void ((string (:ref object))))
;(defpyfun "PyString_InternFromString" string! ((v :string)))
;(defpyfun "PyString_Decode" string! ((s :string) (size ssize-t) (encoding :string) (errors :string)))
;(defpyfun "PyString_AsDecodedObject" string! ((str object) (encoding :string) (errors :string)))
;(defpyfun "PyString_Encode" string! ((s :string) (size ssize-t) (encoding :string) (errors :string)))
;(defpyfun "PyString_AsEncodedObject" string! ((str object) (encoding :string) (errors :string)))

;; TODO PyBytes are #define-aliased to PyString in Python 2
;(defpyfun "PyBytes_FromString"        bytes! ((v :string)))
;(defpyfun "PyBytes_FromStringAndSize" bytes! ((v :string) (len ssize-t)))
;(defpyfun "PyBytes_FromFormat"        bytes! ((format :string) &rest))
;#+requires-va_list-support (defpyfun "PyBytes_FromFormatV"        bytes! ((format :string) (vargs va_list)))
;(defpyfun "PyBytes_Size" ssize-t! ((string object)))
;(defpyfun "PyBytes_AsString" :string ((string object)))
;#+requires-call-by-reference-support (defpyfun "PyBytes_AsStringAndSize" :int ((obj object) (buffer (:ref :string)) (length (:pointer ssize-t))))
;#+requires-call-by-reference-support (defpyfun "PyBytes_Concat" :void ((string (:ref object)) (newpart object)))
;#+requires-call-by-reference-support (defpyfun "PyBytes_ConcatAndDel" :void ((string (:ref object)) (newpart object)))
;#+requires-call-by-reference-support (defpyfun "_PyBytes_Resize" :int ((string (:ref object)) (newsize ssize-t)))
;(defpyfun "PyBytes_Format" object! ((format object) (args tuple)))

;;; Unicode Objects
(defpyfun* unicode.clear-free-list
    (("PyUnicodeUCS2_ClearFreelist" :int ())
     ("PyUnicodeUCS4_ClearFreelist" :int ()))
  (:requires "Python 2.6 (or newer)"))
;; Py_UNICODE_IS* and Py_UNICODE_TO* macros are left out to avoid trying to
;; figure out which actual C function is in use.  If you actually want these
;; things, you'll have to call into Python or something.
(defpyfun* unicode.from-unicode
    (("PyUnicodeUCS2_FromUnicode" unicode! ((u ucs2-string) (size ssize-t)))
     ("PyUnicodeUCS4_FromUnicode" unicode! ((u ucs4-string) (size ssize-t)))))
(defpyfun* unicode.from-string-and-size
    (("PyUnicodeUCS2_FromStringAndSize" unicode! ((u utf8-string) (size ssize-t)))
     ("PyUnicodeUCS4_FromStringAndSize" unicode! ((u utf8-string) (size ssize-t))))
  (:requires "Python 2.6 (or newer)"))
(defpyfun* unicode.from-string
    (("PyUnicodeUCS2_FromString" unicode! ((u utf8-string)))
     ("PyUnicodeUCS4_FromString" unicode! ((u utf8-string))))
  (:requires "Python 2.6 (or newer)"))
(defpyfun* unicode.from-format
    (("PyUnicodeUCS2_FromFormat" unicode! ((format :string) &rest))
     ("PyUnicodeUCS4_FromFormat" unicode! ((format :string) &rest)))
  (:requires "Python 2.6 (or newer)"))
#+requires-va_list-support
(defpyfun* unicode.from-format-v
    (("PyUnicodeUCS2_FromFormatV" unicode! ((format :string) (vargs va_list)))
     ("PyUnicodeUCS4_FromFormatV" unicode! ((format :string) (vargs va_list))))
  (:requires "Python 2.6 (or newer)"))
(defpyfun* unicode.as-unicode ; WARNING!  Do NOT free returned buffer!
    (("PyUnicodeUCS2_AsUnicode" (can-error ucs2-string) ((unicode object)))
     ("PyUnicodeUCS4_AsUnicode" (can-error ucs4-string) ((unicode object)))))
(defpyfun* unicode.get-size
    (("PyUnicodeUCS2_GetSize" ssize-t! ((unicode object)))
     ("PyUnicodeUCS4_GetSize" ssize-t! ((unicode object)))))
(defpyfun* unicode.from-encoded-object
    (("PyUnicodeUCS2_FromEncodedObject" unicode! ((obj object) (encoding :string) (errors :string)))
     ("PyUnicodeUCS4_FromEncodedObject" unicode! ((obj object) (encoding :string) (errors :string)))))
(defpyfun* unicode.from-object
    (("PyUnicodeUCS2_FromObject" unicode! ((obj object)))
     ("PyUnicodeUCS4_FromObject" unicode! ((obj object)))))
#+requires-wchar_t-support
(defpyfun* unicode.from-wide-char
    (("PyUnicodeUCS2_FromWideChar" unicode! ((w wchar-string) (size ssize-t)))
     ("PyUnicodeUCS4_FromWideChar" unicode! ((w wchar-string) (size ssize-t)))))
#+requires-wchar_t-support
(defpyfun* unicode.as-wide-char
    (("PyUnicodeUCS2_AsWideChar" ssize-t! ((unicode unicode) (w wchar-string) (size ssize-t)))
     ("PyUnicodeUCS4_AsWideChar" ssize-t! ((unicode unicode) (w wchar-string) (size ssize-t)))))

;;; Unicode Codecs
;; WARNING!  decode size parameters for the codec functions are bytes, not characters!
(defpyfun* unicode.decode
    (("PyUnicodeUCS2_Decode" unicode! ((s :string) (size ssize-t) (encoding :string) (errors :string)))
     ("PyUnicodeUCS4_Decode" unicode! ((s :string) (size ssize-t) (encoding :string) (errors :string)))))
(defpyfun* unicode.encode
    (("PyUnicodeUCS2_Encode" string! ((s ucs2-string) (size ssize-t) (encoding :string) (errors :string)))
     ("PyUnicodeUCS4_Encode" string! ((s ucs4-string) (size ssize-t) (encoding :string) (errors :string)))))
(defpyfun* unicode.as-encoded-string
    (("PyUnicodeUCS2_AsEncodedString" string! ((unicode unicode) (encoding :string) (errors :string)))
     ("PyUnicodeUCS4_AsEncodedString" string! ((unicode unicode) (encoding :string) (errors :string)))))

;; UTF-8 Codec
(defpyfun* unicode.decode-utf8
    (("PyUnicodeUCS2_DecodeUTF8" unicode! ((s utf8-string) (size ssize-t) (errors :string)))
     ("PyUnicodeUCS4_DecodeUTF8" unicode! ((s utf8-string) (size ssize-t) (errors :string)))))
#+requires-call-by-reference-support
(defpyfun* unicode.decode-utf8-stateful
    (("PyUnicodeUCS2_DecodeUTF8Stateful" unicode! ((s :string) (size ssize-t) (errors :string) (consumed (:ref ssize-t))))
     ("PyUnicodeUCS4_DecodeUTF8Stateful" unicode! ((s :string) (size ssize-t) (errors :string) (consumed (:ref ssize-t))))))
(defpyfun* unicode.encode-utf8
    (("PyUnicodeUCS2_EncodeUTF8" string! ((s ucs2-string) (size ssize-t) (errors :string)))
     ("PyUnicodeUCS4_EncodeUTF8" string! ((s ucs4-string) (size ssize-t) (errors :string)))))
(defpyfun* unicode.as-utf8-string
    (("PyUnicodeUCS2_AsUTF8String" string! ((unicode unicode)))
     ("PyUnicodeUCS4_AsUTF8String" string! ((unicode unicode)))))

;; UTF-32 Codec
#+requires-call-by-reference-support
(defpyfun* unicode.decode-utf32
    (("PyUnicodeUCS2_DecodeUTF32" unicode! ((s ucs4-string) (size ssize-t) (errors :string) (byteorder (:ref :int))))
     ("PyUnicodeUCS4_DecodeUTF32" unicode! ((s ucs4-string) (size ssize-t) (errors :string) (byteorder (:ref :int)))))
  (:requires "Python 2.6 (or newer)"))
#+requires-call-by-reference-support
(defpyfun* unicode.decode-utf32-stateful
    (("PyUnicodeUCS2_DecodeUTF32Stateful" unicode! ((s ucs4-string) (size ssize-t) (errors :string) (byteorder (:ref :int)) (consumed (:ref ssize-t))))
     ("PyUnicodeUCS4_DecodeUTF32Stateful" unicode! ((s ucs4-string) (size ssize-t) (errors :string) (byteorder (:ref :int)) (consumed (:ref ssize-t)))))
  (:requires "Python 2.6 (or newer)"))
(defpyfun* unicode.encode-utf32 ; FIXME: actually returns bytes! (but...that's just an alias for string! anyway)
    (("PyUnicodeUCS2_EncodeUTF32" string! ((s ucs2-string) (size ssize-t) (errors :string) (byteorder :int)))
     ("PyUnicodeUCS4_EncodeUTF32" string! ((s ucs4-string) (size ssize-t) (errors :string) (byteorder :int))))
  (:requires "Python 2.6 (or newer)"))
(defpyfun* unicode.as-utf32-string ; FIXME: actually returns bytes! (but...that's just an alias for string! anyway)
    (("PyUnicodeUCS2_AsUTF32String" string! ((unicode unicode)))
     ("PyUnicodeUCS4_AsUTF32String" string! ((unicode unicode))))
  (:requires "Python 2.6 (or newer)"))

;; UTF-16 Codec
#+requires-call-by-reference-support
(defpyfun* unicode.decode-utf16
    (("PyUnicodeUCS2_DecodeUTF16" unicode! ((s ucs2-string) (size ssize-t) (errors :string) (byteorder (:ref :int))))
     ("PyUnicodeUCS4_DecodeUTF16" unicode! ((s ucs2-string) (size ssize-t) (errors :string) (byteorder (:ref :int))))))
#+requires-call-by-reference-support
(defpyfun* unicode.decode-utf16-stateful
    (("PyUnicodeUCS2_DecodeUTF16Stateful" unicode! ((s ucs2-string) (size ssize-t) (errors :string) (byteorder (:ref :int)) (consumed (:ref ssize-t))))
     ("PyUnicodeUCS4_DecodeUTF16Stateful" unicode! ((s ucs2-string) (size ssize-t) (errors :string) (byteorder (:ref :int)) (consumed (:ref ssize-t))))))
(defpyfun* unicode.encode-utf16
    (("PyUnicodeUCS2_EncodeUTF16" string! ((s ucs2-string) (size ssize-t) (errors :string) (byteorder :int)))
     ("PyUnicodeUCS4_EncodeUTF16" string! ((s ucs4-string) (size ssize-t) (errors :string) (byteorder :int)))))
(defpyfun* unicode.as-utf16-string
    (("PyUnicodeUCS2_AsUTF16String" string! ((unicode unicode)))
     ("PyUnicodeUCS4_AsUTF16String" string! ((unicode unicode)))))

;; UTF-7 Codec
;; NOTE: While passing in pointers to strings should work in theory (say, a
;;       pointer you got from #'unicode.encode-utf7*), we don't actually support
;;       translation of lisp strings to and from utf-7, because babel doesn't
;;       provide it.
(defctype utf7-string (:string :encoding :utf-7))
(defpyfun "PyUnicode_DecodeUTF7" unicode! ((s utf7-string) (size ssize-t) (errors :string)))
#+requires-call-by-reference-support
(defpyfun "PyUnicode_DecodeUTF7Stateful" unicode! ((s utf7-string) (size ssize-t) (errors :string) (consumed (:ref ssize-t))))
;; FIXME: The S argument should actually be a ucs2-string or ucs4-string
;;        depending on which one Python has been compiled to use.  It's a
;;        :pointer for now because we aren't checking here and so might get it
;;        wrong it we assumed.
(defpyfun "PyUnicode_EncodeUTF7" string! ((s :pointer) (size ssize-t) (base64SetO :int) (base64WhiteSpace :int) (errors :string)))

;; Unicode-Escape Codec
;; NOTE: The Unicode-Escape codec is Python specific, and because of that we
;;       only support it through use of pointers gotten from Python, rather than
;;       converted lisp strings.  If it really bothers you, I suppose I could
;;       accept patches to do lisp-side conversion.
(defpyfun* unicode.decode-unicode-escape
    (("PyUnicodeUCS2_DecodeUnicodeEscape" unicode! ((s :pointer) (size ssize-t) (errors :string)))
     ("PyUnicodeUCS4_DecodeUnicodeEscape" unicode! ((s :pointer) (size ssize-t) (errors :string)))))
(defpyfun* unicode.encode-unicode-escape
    (("PyUnicodeUCS2_EncodeUnicodeEscape" string! ((s ucs2-string) (size ssize-t)))
     ("PyUnicodeUCS4_EncodeUnicodeEscape" string! ((s ucs4-string) (size ssize-t)))))
(defpyfun* unicode.as-unicode-escape-string
    (("PyUnicodeUCS2_AsUnicodeEscapeString" string! ((unicode unicode)))
     ("PyUnicodeUCS4_AsUnicodeEscapeString" string! ((unicode unicode)))))

;; Raw-Unicode-Escape Codec
;; NOTE: The Raw-Unicode-Escape codec is Python specific, and because of that we
;;       only support it through use of pointers gotten from Python, rather than
;;       converted lisp strings.  If it really bothers you, I suppose I could
;;       accept patches to do lisp-side conversion.
(defpyfun* unicode.decode-raw-unicode-escape
    (("PyUnicodeUCS2_DecodeRawUnicodeEscape" unicode! ((s :pointer) (size ssize-t) (errors :string)))
     ("PyUnicodeUCS4_DecodeRawUnicodeEscape" unicode! ((s :pointer) (size ssize-t) (errors :string)))))
(defpyfun* unicode.encode-raw-unicode-escape
    (("PyUnicodeUCS2_EncodeRawUnicodeEscape" string! ((s ucs2-string) (size ssize-t) (errors :string)))
     ("PyUnicodeUCS4_EncodeRawUnicodeEscape" string! ((s ucs4-string) (size ssize-t) (errors :string)))))
(defpyfun* unicode.as-raw-unicode-escape-string
    (("PyUnicodeUCS2_AsRawUnicodeEscapeString" string! ((unicode unicode)))
     ("PyUnicodeUCS4_AsRawUnicodeEscapeString" string! ((unicode unicode)))))

;; Latin-1 Codec
(defctype latin1-string (:string :encoding :latin-1))
(defpyfun* unicode.decode-latin1
    (("PyUnicodeUCS2_DecodeLatin1" unicode! ((s latin1-string) (size ssize-t) (errors :string)))
     ("PyUnicodeUCS4_DecodeLatin1" unicode! ((s latin1-string) (size ssize-t) (errors :string)))))
(defpyfun* unicode.encode-latin1
    (("PyUnicodeUCS2_EncodeLatin1" string! ((s ucs2-string) (size ssize-t) (errors :string)))
     ("PyUnicodeUCS4_EncodeLatin1" string! ((s ucs4-string) (size ssize-t) (errors :string)))))
(defpyfun* unicode.as-latin1-string
    (("PyUnicodeUCS2_AsLatin1String" string! ((unicode unicode)))
     ("PyUnicodeUCS4_AsLatin1String" string! ((unicode unicode)))))

;; ASCII Codec
(defctype ascii-string (:string :encoding :ascii))
(defpyfun* unicode.decode-ascii
    (("PyUnicodeUCS2_DecodeASCII" unicode! ((s ascii-string) (size ssize-t) (errors :string)))
     ("PyUnicodeUCS4_DecodeASCII" unicode! ((s ascii-string) (size ssize-t) (errors :string)))))
(defpyfun* unicode.encode-ascii
    (("PyUnicodeUCS2_EncodeASCII" string! ((s ucs2-string) (size ssize-t) (errors :string)))
     ("PyUnicodeUCS4_EncodeASCII" string! ((s ucs4-string) (size ssize-t) (errors :string)))))
(defpyfun* unicode.as-ascii-string
    (("PyUnicodeUCS2_AsASCIIString" string! ((unicode unicode)))
     ("PyUnicodeUCS4_AsASCIIString" string! ((unicode unicode)))))

;; Character Map Codec
;; NOTE: mapping and table arguments are probably dicts, but could be other
;;       things as well (hence why they're left as general objects, rather than
;;       being specified).
(defpyfun* unicode.decode-charmap
    (("PyUnicodeUCS2_DecodeCharmap" unicode! ((s :string) (size ssize-t) (mapping object) (errors :string)))
     ("PyUnicodeUCS4_DecodeCharmap" unicode! ((s :string) (size ssize-t) (mapping object) (errors :string)))))
(defpyfun* unicode.encode-charmap
    (("PyUnicodeUCS2_EncodeCharmap" string! ((s ucs2-string) (size ssize-t) (mapping object) (errors :string)))
     ("PyUnicodeUCS4_EncodeCharmap" string! ((s ucs4-string) (size ssize-t) (mapping object) (errors :string)))))
(defpyfun* unicode.as-charmap-string
    (("PyUnicodeUCS2_AsCharmapString" string! ((unicode unicode) (mapping object)))
     ("PyUnicodeUCS4_AsCharmapString" string! ((unicode unicode) (mapping object)))))
(defpyfun* unicode.translate-charmap
    (("PyUnicodeUCS2_TranslateCharmap" unicode! ((s ucs2-string) (size ssize-t) (table object) (errors :string)))
     ("PyUnicodeUCS4_TranslateCharmap" unicode! ((s ucs4-string) (size ssize-t) (table object) (errors :string)))))

;; MBCS codecs (for Windows)
;; NOTE: The MBCS codecs are Windows- and machine-setting-specific, so we only
;;       support them through use of Python-supplied pointers.
(defpyfun "PyUnicode_DecodeMBCS" unicode! ((s :pointer) (size ssize-t) (errors :string))
  (:requires "Windows"))
#+requires-call-by-reference-support
(defpyfun ("PyUnicode_DecodeMBCSStateful" unicode.decode-mbcs-stateful) unicode! ((s :pointer) (size :int) (errors :string) (consumed (:ref :int)))
  (:requires "Windows"))
;; FIXME: The S argument should actually be a ucs2-string or ucs4-string
;;        depending on which one Python has been compiled to use.  It's a
;;        :pointer for now because we aren't checking here and so might get it
;;        wrong it we assumed.
(defpyfun "PyUnicode_EncodeMBCS" string! ((s :pointer) (size ssize-t) (errors :string))
  (:requires "Windows"))
(defpyfun ("PyUnicode_AsMBCSString" unicode.as-mbcs-string) string! ((unicode unicode))
  (:requires "Windows"))

;; Methods and Slots
(defpyfun* unicode.concat
    (("PyUnicodeUCS2_Concat" unicode! ((left object) (right object)))
     ("PyUnicodeUCS4_Concat" unicode! ((left object) (right object)))))
(defpyfun* unicode.split
    (("PyUnicodeUCS2_Split" list! ((s object) (sep object) (maxsplit ssize-t)))
     ("PyUnicodeUCS4_Split" list! ((s object) (sep object) (maxsplit ssize-t)))))
(defpyfun* unicode.splitlines
    (("PyUnicodeUCS2_Splitlines" list! ((s object) (keepend :int)))
     ("PyUnicodeUCS4_Splitlines" list! ((s object) (keepend :int)))))
(defpyfun* unicode.translate
    (("PyUnicodeUCS2_Translate" unicode! ((str object) (table object) (errors :string)))
     ("PyUnicodeUCS4_Translate" unicode! ((str object) (table object) (errors :string)))))
(defpyfun* unicode.join
    (("PyUnicodeUCS2_Join" unicode! ((separator object) (seq object)))
     ("PyUnicodeUCS4_Join" unicode! ((separator object) (seq object)))))
(defpyfun* unicode.tailmatch
    (("PyUnicodeUCS2_Tailmatch" boolean! ((str object) (substr object) (start ssize-t) (end ssize-t) (direction :int)))
     ("PyUnicodeUCS4_Tailmatch" boolean! ((str object) (substr object) (start ssize-t) (end ssize-t) (direction :int)))))
(defpyfun* unicode.find
    (("PyUnicodeUCS2_Find" ssize-t! ((str object) (substr object) (start ssize-t) (end ssize-t) (direction :int)))
     ("PyUnicodeUCS4_Find" ssize-t! ((str object) (substr object) (start ssize-t) (end ssize-t) (direction :int)))))
(defpyfun* unicode.count
    (("PyUnicodeUCS2_Count" ssize-t! ((str object) (substr object) (start ssize-t) (end ssize-t)))
     ("PyUnicodeUCS4_Count" ssize-t! ((str object) (substr object) (start ssize-t) (end ssize-t)))))
(defpyfun* unicode.replace
    (("PyUnicodeUCS2_Replace" unicode! ((str object) (substr object) (replstr object) (maxcount ssize-t)))
     ("PyUnicodeUCS4_Replace" unicode! ((str object) (substr object) (replstr object) (maxcount ssize-t)))))
(defpyfun* unicode.compare
    (("PyUnicodeUCS2_Compare" :int ((left object) (right object)))
     ("PyUnicodeUCS4_Compare" :int ((left object) (right object)))))
(defpyfun* unicode.rich-compare
    (("PyUnicodeUCS2_RichCompare" object! ((left object) (right object) (op :int)))
     ("PyUnicodeUCS4_RichCompare" object! ((left object) (right object) (op :int)))))
(defpyfun* unicode.format
    (("PyUnicodeUCS2_Format" unicode! ((format object) (args object)))
     ("PyUnicodeUCS4_Format" unicode! ((format object) (args object)))))
(defpyfun* unicode.contains
    (("PyUnicodeUCS2_Contains" boolean! ((container object) (element object)))
     ("PyUnicodeUCS4_Contains" boolean! ((container object) (element object)))))

;;; TODO Buffers and Memoryview Objects

;;; Tuple Objects
(defpyfun "PyTuple_New"  tuple! ((len ssize-t)))
(defpyfun "PyTuple_Pack" tuple! ((n ssize-t) &rest)) ; remaining args are pointers to PyObjects
(defpyfun "PyTuple_Size" ssize-t! ((p object)))
(defpyfun "PyTuple_GetItem" (object! :borrowed) ((p tuple) (pos ssize-t)))
(defpyfun "PyTuple_GetSlice" tuple! ((p tuple) (low ssize-t) (high ssize-t)))
(defpyfun "PyTuple_SetItem" 0-on-success ((p tuple) (pos ssize-t) (o (object :stolen))))
#+requires-call-by-reference-support (defpyfun "_PyTuple_Resize" 0-on-success ((p (:ref object)) (newsize ssize-t)))
(defpyfun "PyTuple_ClearFreeList" :int ()
  (:requires "Python 2.6 (or newer)"))

;;; TODO List Objects

;;;; TODO Mapping Objects
;;; TODO Dictionary Objects

;;;; TODO Other Objects
;;; TODO Class and Instance Objects
;;; TODO Function Objects
;;; TODO Method Objects
;;; TODO File Objects
;;; TODO Module Objects
;;; TODO Iterator Objects
;;; TODO Descriptor Objects
;;; TODO Slice Objects
;;; TODO Weak Reference Objects
;;; TODO Capsules
;;; TODO CObjects
;;; TODO Cell Objects
;;; TODO Generator Objects
;;; TODO DateTime Objects
;;; TODO Set Objects
;;; TODO Code Objects

;;;; TODO: Memory Management
;;;; TODO: Object Implementation Support (Allocating, Structures, Types, GC)

;; FIXME: reorder to better match order of Python's docs
;; FIXME: some of these :POINTERs should probably be OBJECTs (or DICTs, etc.)
;; FIXME: we also need a way to say "returns NULL on error" or "-1 on error"
(defpyfun "PyDict_New" dict ())
(defpyfun "PyDict_Keys" list ((d :pointer)))
(defpyfun "PyDict_Size" ssize-t ((d :pointer)))
(defpyfun "PyDict_GetItem" (object :borrowed) ((d :pointer) (key object)))
(defpyfun "PyDict_GetItemString" (object :borrowed) ((d :pointer) (key string)))
(defpyfun "PyDict_Items" list ((d :pointer)))
(defpyfun "PyDict_SetItem" :int ((d :pointer) (key object) (val object))) ; canerr
(defpyfun "PyImport_GetModuleDict" dict ())
(defpyfun "PyImport_Import" object! ((name string)))
(defpyfun "PyImport_ImportModule" (can-error :pointer) ((name :string)))
(defpyfun "PyImport_ImportModuleEx" (can-error :pointer) ((name :string) (globals :pointer) (locals :pointer) (fromlist :pointer))
  (:implementation (import.import-module-level name globals locals fromlist -1)))
(defpyfun "PyImport_ImportModuleLevel" (can-error :pointer) ((name :string) (globals :pointer) (locals :pointer) (fromlist :pointer) (level :int)))
(defpyfun "PyImport_AddModule" :pointer ((name :string)))
(defpyfun "PyList_New" list ((size :int)))
(defpyfun "PyList_Size" :int ((lst :pointer)))
(defpyfun "PyList_GetItem" (object :borrowed) ((lst :pointer) (index :int)))
(defpyfun "PyList_SetItem" :int ((lst :pointer) (index :int) (o object)))
(defpyfun "PyModule_GetDict" dict ((m :pointer)))

#+(or) ;; WARNING: don't trace if lots of data.  (feedparser.parse(my-lj) produces ~195k lines)
(trace translate-to-foreign translate-from-foreign free-translated-object
       %object.refcnt
       string.from-string* string.from-string
       unicode.from-unicode* unicode.from-unicode unicode-ucs4.from-unicode* unicode-ucs4.from-unicode
       .inc-ref .dec-ref
       object.type-check object.check type.check int.check string.check
       dict.new* dict.new dict.set-item dict.items dict.items* dict.get-item*
       tuple.get-item
       list.size)