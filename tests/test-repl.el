;;; test-repl.el ---  -*- lexical-binding: t; -*-
;;
;; Filename: test-repl.el
;; Author: Daniel Barreto
;; Copyright (C) 2017 Daniel Barreto
;; Created: Sun Dec 17 23:42:58 2017 (+0100)
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Commentary:
;;
;; Test REPL stuff
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or (at
;; your option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Code:

(require 'buttercup)
(require 'with-simulated-input)

(require 'spiral)


(defun wait-for-aux (conn-id)
  "Wait while a new prompt is available in `:aux' conn for CONN-ID."
  (while (spiral-pending-eval :aux conn-id)
    (accept-process-output nil 0.01)))


(defmacro describe-evaluation (&rest opts)
  "Expand to a buttercup `it' form that ensures correct behavior for an input.
OPTS should be a plist that contains `:input' and `:expected' properties.
The `:input' property is what is going to be send through the wire to the
connected REPL, as if it were typed by a user.
The `:expected' property is the string that should appear in the
REPL (without text properties) after the input is sent, and before the
start of the next prompt."
  (let* ((input (plist-get opts :input))
         (expected (plist-get opts :expected))
         (test-name (format "correctly evaluates $> %s" input)))
    `(it ,test-name
       (with-current-buffer "SPIRAL[localhost:5555]"
         (goto-char (point-max))
         (insert ,input)
         (let ((history-count (length spiral-repl-history))
               (end-of-input (point)))
           (spiral-repl-return)
           ;; There should be a client pending evaluation
           (with-process-buffer 'localhost:5555 :client
             (expect (length spiral-pending-evals) :to-equal 1))
           ;; Wait til the next prompt is there
           (while spiral-repl-inputting
             (accept-process-output nil 0.1))
           ;; And after the prompt, no more pending evaluations
           (with-process-buffer 'localhost:5555 :client
             (expect (length spiral-pending-evals) :to-equal 0))
           ;; Check history
           (let ((he (car spiral-repl-history)))
             (expect (spiral-repl--history-entry-idx he) :to-equal (1+ history-count))
             (expect (spiral-repl--history-entry-str he) :to-equal ,input)
             (expect (spiral-repl--history-entry-prompt-marker he) :to-equal spiral-repl-prompt-start-mark))
           ;; Get evaluation result, without really paying attention to text
           ;; properties.
           (expect (buffer-substring-no-properties
                    (1+ end-of-input)
                    (1- spiral-repl-prompt-start-mark))
                   :to-equal
                   ,expected))))))


(describe "REPL"
  (before-all
    (spiral--connect-to "localhost" 5555)
    (with-current-buffer "SPIRAL[localhost:5555]"  ;; wait for it to start.
      (while (null (marker-buffer spiral-repl-prompt-start-mark))
        (accept-process-output nil 0.1))))

  (after-all
    (spiral-quit 'do-it 'localhost:5555))

  (describe "buffer"
    (describe-evaluation
     :input ":foo"
     :expected "> :foo")

    (describe-evaluation
     :input "{:foo 'bar}"
     :expected "> {:foo bar}")

    (describe-evaluation
     :input "(+ 1 1)"
     :expected "> 2")

    (describe-evaluation
     :input "(def square #(* % %))"
     :expected "> user/square")

    (describe-evaluation
     :input "(square 5)"
     :expected "> 25")

    (describe-evaluation
     :input "(/ 1 2)"
     :expected "> 1/2")

    (describe-evaluation
     :input "(range 100)"
     :expected "> (0 1 2 3 4 5 6 7 8 9  ...)")

    (describe-evaluation
     :input "(into [] (range 100))"
     :expected "> [0 1 2 3 4 5 6 7 8 9  ...]")

    (describe-evaluation
     :input "(into #{} (range 100))"
     :expected "> #{0 65 70 62 74 7 59 86 20 72  ...}")

    (describe-evaluation
     :input "(str (apply str (repeat 27 \"Na \")) \"Batman!\")"
     :expected "> \"Na Na Na Na Na Na Na Na Na Na Na Na Na Na Na Na Na Na Na Na Na Na Na Na Na Na Na\" ...")

    (describe-evaluation
     :input "(println \"spiral?\")"
     :expected "spiral?\n> nil")

    (describe-evaluation
     :input "(print \"stroem?\")"
     :expected "stroem?%\n> nil")

    (describe-evaluation
     :input "(binding [*out* *err*] (println \"oh noes...\"))"
     :expected "oh noes...\n> nil")

    (describe-evaluation
     :input "(zipmap (map char (range 97 (+ 97 26))) (range 26))"
     :expected "> {\\a 0 \\b 1 \\c 2 \\d 3 \\e 4 \\f 5 \\g 6 \\h 7 \\i 8 \\j 9  ...}")

    (describe-evaluation
     :input "1 2 3"
     :expected "> 1\n> 2\n> 3")

    (describe-evaluation
     :input "(/ 1 0)"
     :expected "~ Unhandled Exception
  java.lang.ArithmeticException: Divide by zero

 [Show Trace]
")

    (describe-evaluation
     :input "(map / (iterate dec 3))"
     :expected "> (1/3 1/2 1 ~lazy-error \"Divide by zero\" [Inspect]~)")

    (describe-evaluation
     :input "/not-an-input"
     :expected "UNREPL could not read this input
               java.lang.RuntimeException: Invalid token: /not-an-input
  clojure.lang.LispReader$ReaderException: java.lang.RuntimeException: Invalid token: /not-an-input

 [Show Trace]
")

    ;; (describe-evaluation
    ;;  :input ""
    ;;  :expected "")

    ;; Test clicking elisions
    )

  (describe "interactive"
    (it "`spiral-request-symbol-doc' works"
      (with-current-buffer "SPIRAL[localhost:5555]"
        (goto-char (point-max))
        (insert "(map")
        (call-interactively #'spiral-request-symbol-doc)
        (wait-for-aux 'localhost:5555)
        (let ((transient-text (buffer-substring-no-properties
                               spiral-repl-transient-text-start-mark
                               spiral-repl-transient-text-end-mark)))
          (expect transient-text
                  :to-equal
                  (concat "-------------------------\n"
                          "clojure.core/map\n"
                          "([f] [f coll] [f c1 c2] [f c1 c2 c3] [f c1 c2 c3 & colls])\n"
                          "  Returns a lazy sequence consisting of the result of applying f to\n"
                          "  the set of first items of each coll, followed by applying f to the\n"
                          "  set of second items in each coll, until any one of the colls is\n"
                          "  exhausted.  Any remaining items in other colls are ignored. Function\n"
                          "  f should accept number-of-colls arguments. Returns a transducer when\n"
                          "  no collection is provided.\n")))
        (insert "inc (range 3))")
        (spiral-repl-return)
        (expect (and (null (marker-position spiral-repl-transient-text-start-mark))
                     (null (marker-position spiral-repl-transient-text-end-mark)))))))

  (describe "completion"
    (it "returns correct candidates"
      (with-current-buffer "SPIRAL[localhost:5555]"
        (let ((candidates (spiral-complete--candidates "red"))
              (expected '("reduce" "reduced" "reduced?" "reduce-kv" "reductions")))
          (dolist (candidate candidates)
            (expect (substring-no-properties candidate) :to-equal (pop expected))
            (expect (get-text-property 0 'type candidate) :to-equal :function)
            (expect (get-text-property 0 'ns candidate) :to-equal "clojure.core"))))))

  (describe "when buffer is killed by user"
    :var (connected-buffer-list)

    (before-all
      (dolist (buffer-name '("core.clj" "test.clj" "utils.clj"))
        (with-current-buffer (get-buffer-create buffer-name)
          (clojure-mode)
          (let ((inhibit-message t))
            (spiral--connect-to "localhost" 5555))
          (push (current-buffer) connected-buffer-list)))
      (with-simulated-input "y RET"
        (kill-buffer "SPIRAL[localhost:5555]")))

    (it "localhost:5555 is no longer in the available projects"
      (expect (length spiral-projects) :to-equal 0))

    (it "no other buffer will still be connected to localhost:5555"
      (dolist (buffer connected-buffer-list)
        (expect (buffer-local-value 'spiral-conn-id buffer) :to-equal nil)))))

;;; test-repl.el ends here
