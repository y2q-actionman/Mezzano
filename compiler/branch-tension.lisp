(in-package :sys.c)

;;;; This pass works on a LAP program.
;;;; It removes unused labels, tensions branches to unconditional branches,
;;;; converts sequences like "je over; jmp elsewhere; over:" to "jne elsewhere",
;;;; and eliminates dead instructions between unconditional jumps and labels.
;;;;
;;;; Beware! There is limited support for referencing labels from non-jump instructions.
;;;; Used by various things (sys.lap-x86:lea reg (:rip label))
;;;; Used by tagbody: (:d64/le (- label label))

(defun tension-branches (program)
  (let ((all-labels (remove-if-not #'symbolp program))
        (loop-count 0))
    (loop
       (incf loop-count)
       (when (> loop-count 10)
         (warn 'sys.int::simple-style-warning
               :format-control "Bailing out of branch-tensioner")
         (return program))
       (let ((label-targets (find-label-targets program)))
         (multiple-value-bind (tensioned-program change-count)
             (tension-branches-1 program label-targets)
           (let* ((label-uses (find-label-uses tensioned-program all-labels))
                  (unused-labels (remove-if (lambda (label) (gethash label label-uses))
                                            all-labels)))
             (setf program (remove-if (lambda (x) (member x unused-labels)) tensioned-program))
             (when (zerop change-count)
               (return program))))))))

(defun tension-branches-1 (program label-targets)
  (do ((after-unconditional-jmp nil)
       (change-count 0)
       (i program (cdr i))
       (new-program '()))
      ((null i)
       (values (nreverse new-program)
               change-count))
    (let ((form (car i)))
      (when (symbolp form)
        (setf after-unconditional-jmp nil))
      (when after-unconditional-jmp
        ;; This instruction is being dropped.
        (incf change-count))
      (unless after-unconditional-jmp
        (cond ((not (consp form))
               (push form new-program))
              ((and (or (find (first form) *predicate-instructions* :key #'third)
                        (eql (first form) 'sys.lap-x86:jmp))
                    (symbolp (cadr i))
                    (eql (gethash (second form) label-targets)
                         (gethash (cadr i) label-targets)))
               ;; (Jmp label)
               ;; label
               ;; Do nothing to eliminate the instruction.
               (incf change-count))
              ((and (find (first form) *predicate-instructions* :key #'third)
                    (listp (cadr i))
                    (eql (first (cadr i)) 'sys.lap-x86:jmp)
                    (symbolp (caddr i))
                    (eql (gethash (second form) label-targets)
                         (gethash (caddr i) label-targets)))
               ;; (Jcc over)
               ;; (JMP label)
               ;; over
               ;; Invert the Jcc condition, point it to label and eliminate the JMP.
               (push (list (third (predicate-info (second (find (first form) *predicate-instructions* :key #'third))))
                           (second (cadr i)))
                     new-program)
               ;; Skip the JMP.
               (setf i (cdr i))
               (incf change-count))
              ((or (find (first form) *predicate-instructions* :key #'third)
                   (eql (first form) 'sys.lap-x86:jmp))
               (when (eql (first form) 'sys.lap-x86:jmp)
                 (setf after-unconditional-jmp t))
               ;; Jcc or JMP
               (let* ((label (second form))
                      (target (gethash label label-targets)))
                 (cond ((and target
                             (eql (first (car target)) 'sys.lap-x86:jmp))
                        ;; It's a jump-to-unconditional-jump! Rewrite it.
                        (push (list (first form) (second (car target)))
                              new-program)
                        (incf change-count))
                       (t (push form new-program)))))
               (t (push form new-program)))
              ))))

(defun find-label-uses (program all-labels)
  (let ((uses (make-hash-table :test 'eq)))
    (dolist (f program)
      (when (consp f)
        ;; Check for a Jcc or JMP
        (cond ((and (or (find (first f) *predicate-instructions* :key #'third)
                        (eql (first f) 'sys.lap-x86:jmp))
                    (member (second f) all-labels))
               (push f (gethash (second f) uses)))
              ;; RIP-relative LEA64. :RIP must be first in the effective address!
              ((and (eql (first f) 'sys.lap-x86:lea64)
                    (eql (first (third f)) :rip)
                    (member (second (third f)) all-labels))
               (push f (gethash (second (third f)) uses)))
              ;; D64/LE, for tagbody jump tables.
              ((and (eql (first f) :d64/le)
                    (listp (second f))
                    (= (length (second f)) 3)
                    (eql (first (second f)) '-))
               (when (member (second (second f)) all-labels)
                 (push f (gethash (second (second f)) uses)))
               (when (member (third (second f)) all-labels)
                 (push f (gethash (third (second f)) uses)))))))
    uses))

(defun find-label-targets (program)
  (let ((targets (make-hash-table :test 'eq)))
    (do ((i program (cdr i)))
        ((null i))
      (when (symbolp (car i))
        ;; Search forward until a non-label is found.
        (do ((j i (cdr j)))
            ((or (not (symbolp (car j)))
                 (null j))
             (setf (gethash (car i) targets) j)))))
    targets))