;;; org-win-find-file.el --- Open files in a split window layout via an org link  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dov Grobgeld
;;
;; Author: Dov Grobgeld <dov.grobgeld@gmail.com>
;; Assisted-by: Claude Code:claude-sonnet-5
;; Maintainer: Dov Grobgeld <dov.grobgeld@gmail.com>
;; Created: 13 Jul 2026
;; Version: 0.02
;; Package-Requires: ((emacs "26.1") (org "9.3"))
;; Keywords: outlines convenience frames
;; URL: https://github.com/dov/org-win-find-file

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

;;; Commentary:

;; Defines a "win:" org link type that opens one or more targets in a
;; freshly built, possibly nested window layout.  The link path is an
;; expression built from targets and two split operators:
;;
;;   |   horizontal split -- windows placed side by side (left to right)
;;   ÷   vertical split   -- windows stacked (top to bottom)
;;
;; Parentheses group sub-layouts.  "÷" binds looser than "|", so
;; "a|b÷c" is read as "(a|b) ÷ c".  Windows are evenly sized at each
;; level (`balance-windows').
;;
;; Each target is either another org link (e.g. "git:xjb"), opened
;; through org's own link machinery, or a plain file path opened with
;; `find-file'.
;;
;; A target may carry a suffix of window options, written between
;; guillemets («...») immediately after the target.  Options are
;; separated by commas; each is a single-letter key, optionally
;; "key=value":
;;
;;   s        sticky -- mark the window dedicated to its buffer (see
;;            `set-window-dedicated-p') so Emacs will not reuse it to
;;            display another buffer.
;;   f        focus -- leave point in this window once the layout is
;;            built (otherwise the top-left window is selected).
;;   r        read-only -- visit the buffer in `read-only-mode'.
;;   o        no-other-window -- skip this window when cycling with
;;            `other-window' (C-x o).
;;   a        auto-revert -- enable `auto-revert-mode' in the buffer.
;;   F        fit -- shrink the window to its buffer's contents with
;;            `fit-window-to-buffer'.
;;   w=SIZE   size -- give the window SIZE along its split axis, either
;;            a percentage ("40%") of the enclosing split or an
;;            absolute number of columns/lines ("80").
;;
;; Several options may be combined, e.g. "target«s,r,w=40%»".  A link
;; whose final target carries a suffix must be written in bracketed
;; form ("[[win:...]]"), since a plain link would lose its trailing
;; guillemet.
;;
;; Examples:
;;   [[win:git:xjb]]
;;       Open git:xjb in a single window.
;;   [[win:git:xjb|git:xjb@proto]]
;;       Two windows side by side, git:xjb on the left.
;;   [[win:git:xjb«s,f»|doc.org«r,w=40%»]]
;;       git:xjb sticky and focused on the left; doc.org read-only on
;;       the right, sized to 40% of the split.
;;   [[win:foo.bar÷(wuz.bar|maz.bar)]]
;;       foo.bar on top; below it wuz.bar and maz.bar side by side.
;;   [[win:/etc/fstab÷/backup/etc/fstab]]
;;       Two plain files stacked top over bottom.

;; Put this file into your load-path and the following into your ~/.emacs:
;;   (require 'org-win-find-file)

;;; Code:

(require 'org)
(require 'cl-lib)

(org-link-set-parameters "win" :follow #'org-win-find-file-open)

(defconst org-win-find-file-vsplit-char ?÷
  "Character separating windows stacked top to bottom (vertical split).")

(defconst org-win-find-file-hsplit-char ?|
  "Character separating windows placed side by side (horizontal split).")

(defconst org-win-find-file-suffix-open ?«
  "Character that opens a target's window-flags suffix.
Note that a suffix that ends the link only survives inside a
bracketed org link (\"[[win:...]]\"): Emacs's `org-link-plain-re'
trims a trailing guillemet from a plain (unbracketed) link.")

(defconst org-win-find-file-suffix-close ?»
  "Character that closes a target's window-flags suffix.")

(defconst org-win-find-file-suffix-separator ","
  "Separator (a regexp) between options inside a target's suffix.")

(cl-defstruct (org-win-find-file-leaf
               (:constructor org-win-find-file--make-leaf)
               (:copier nil))
  "A layout leaf: a single TARGET plus its window OPTIONS.
OPTIONS is an alist parsed from the guillemet suffix (see the
commentary).  Each entry is (KEY . VALUE) where KEY is the option
string (e.g. \"s\") and VALUE is t for a boolean option or the
string right of \"=\" for a valued one, e.g. ((\"s\" . t) (\"w\" . \"40%\"))."
  target
  flags)

(defvar org-win-find-file-debug nil
  "When non-nil, log to *Messages* how each target is resolved.
Useful for diagnosing why an already-open remote (tramp) file is
not being reused.")

(defvar org-win-find-file--target-buffers (make-hash-table :test 'equal)
  "Cache mapping a win: target string to the buffer it last opened.
Lets a repeated follow of the same target just redisplay its
buffer instead of re-running the follow handler, which for remote
\(tramp) targets -- e.g. a git:/magit repo -- would otherwise incur
a slow remote access on every follow.")

(defun org-win-find-file-forget-buffers ()
  "Clear the win: target buffer cache.
Use this to force the next follow to re-run its handlers (e.g. to
refresh a magit status buffer)."
  (interactive)
  (clrhash org-win-find-file--target-buffers))

(defun org-win-find-file--visiting-buffer (filename)
  "Return an existing buffer visiting FILENAME, or nil.
Matching is purely string based, so it never contacts a remote
host.  Besides an exact expanded-name match, a remote FILENAME is
also matched when the host and local file name agree, which
tolerates tramp normalizing the method/user differently in the
link than in the live buffer's variable `buffer-file-name'."
  (let* ((want (expand-file-name filename))
         (want-host (file-remote-p want 'host))
         (want-local (file-remote-p want 'localname)))
    (or (get-file-buffer want)
        (catch 'hit
          (dolist (buf (buffer-list))
            (let ((bfn (buffer-local-value 'buffer-file-name buf)))
              (when bfn
                (let ((bfe (expand-file-name bfn)))
                  (when (or (string= bfe want)
                            (and want-host
                                 (equal want-host (file-remote-p bfe 'host))
                                 (equal want-local (file-remote-p bfe 'localname))))
                    (throw 'hit buf))))))
          nil))))

(defun org-win-find-file--parse-flags (spec)
  "Parse SPEC, a comma-separated option list, into an alist.
Each option is KEY or KEY=VALUE; boolean options get the value t.
Whitespace around options is ignored.  See the commentary."
  (let (alist)
    (dolist (opt (split-string spec org-win-find-file-suffix-separator
                               t "[ \t]+"))
      (if (string-match "\\`\\([^=]+\\)=\\(.*\\)\\'" opt)
          (push (cons (match-string 1 opt) (match-string 2 opt)) alist)
        (push (cons opt t) alist)))
    (nreverse alist)))

(defvar org-win-find-file--focus-window nil
  "Window marked with the `f' (focus) option, selected after layout.
Bound dynamically while `org-win-find-file-open' builds a layout.")

(defvar org-win-find-file--deferred nil
  "Thunks applied after `balance-windows', for size-related options.
Bound dynamically while `org-win-find-file-open' builds a layout.")

(defvar org-win-find-file--sized-windows nil
  "Windows given an explicit size by the `w' or `F' options.
After the sizes are applied these windows are pinned while the
layout is re-balanced, so their unsized siblings share the
remaining space evenly.  Bound dynamically by
`org-win-find-file-open'.")

(defun org-win-find-file--pin-window-size (window)
  "Pin WINDOW's size along its split axis via `window-size-fixed'.
Set buffer-locally so `balance-windows' leaves WINDOW alone.  The
caller is responsible for undoing this with `kill-local-variable'."
  (let ((axis (if (window-combined-p window t) 'width 'height)))
    (with-current-buffer (window-buffer window)
      (setq-local window-size-fixed axis))))

(defun org-win-find-file--apply-size (window spec)
  "Resize WINDOW to SPEC along its split axis.
SPEC is a percentage of the enclosing split (\"40%\") or an
absolute number of columns/lines (\"80\")."
  (let ((horiz (window-combined-p window t)))
    (when (window-parent window)        ; a lone window has nothing to take from
      (let* ((parent (window-parent window))
             (total (if horiz (window-total-width parent)
                      (window-total-height parent)))
             (target (if (string-suffix-p "%" spec)
                         (round (* total (/ (string-to-number spec) 100.0)))
                       (string-to-number spec)))
             (current (if horiz (window-total-width window)
                        (window-total-height window))))
        (condition-case err
            (window-resize window (- target current) horiz)
          (error
           (when org-win-find-file-debug
             (message "org-win-find-file: cannot size %S to %s: %s"
                      window spec (error-message-string err)))))))))

(defun org-win-find-file--open-target (leaf)
  "Open LEAF's target in the selected window and apply its flags.
LEAF is an `org-win-find-file-leaf'.  If its target has a
registered org link type prefix (e.g. \"git:...\") it is opened
through org's link machinery, otherwise it is treated as a file
name and opened with `find-file'.  A `?s' (sticky) flag marks the
window dedicated to its buffer via `set-window-dedicated-p'."
  (let ((target (org-win-find-file-leaf-target leaf))
        (cached (gethash (org-win-find-file-leaf-target leaf)
                         org-win-find-file--target-buffers))
        ;; Force the target into the window we just selected, overriding any
        ;; custom display logic the follow handler might use (e.g. magit
        ;; places its status buffers in a window of its own choosing, which
        ;; otherwise scrambles the requested layout).
        (display-buffer-overriding-action
         '((display-buffer-same-window) (inhibit-same-window . nil))))
    (cond
     ;; This target was opened before by a win: link and its buffer is still
     ;; alive -- just redisplay it.  We never re-run the follow handler, so a
     ;; remote (tramp) target incurs no remote access on a repeated follow.
     ((buffer-live-p cached)
      (when org-win-find-file-debug
        (message "org-win-find-file: %S -> cached buffer %S"
                 target (buffer-name cached)))
      (switch-to-buffer cached))
     (t
      (let ((type (and (string-match "\\`\\([a-zA-Z][a-zA-Z0-9+.-]*\\):" target)
                       (match-string 1 target))))
        (if (and type (member type (org-link-types)))
            (org-link-open-from-string (concat "[[" target "]]"))
          ;; Plain file path.  For an already-open remote (tramp) file, reuse
          ;; the existing buffer rather than revisiting it -- `find-file'
          ;; would otherwise re-read the file over the remote connection.
          (let ((existing (and (file-remote-p target)
                               (org-win-find-file--visiting-buffer target))))
            (if existing
                (switch-to-buffer existing)
              (find-file target)))))
      ;; Remember which buffer this target produced, for the next follow.
      (puthash target (window-buffer (selected-window))
               org-win-find-file--target-buffers)
      (when org-win-find-file-debug
        (message "org-win-find-file: %S -> opened %S"
                 target (buffer-name (window-buffer (selected-window)))))))
    ;; Apply the window options carried by the suffix.
    (let ((win (selected-window))
          (flags (org-win-find-file-leaf-flags leaf)))
      (when (assoc "s" flags)
        (set-window-dedicated-p win t))
      (when (assoc "o" flags)
        (set-window-parameter win 'no-other-window t))
      (when (assoc "r" flags)
        (with-current-buffer (window-buffer win) (read-only-mode 1)))
      (when (assoc "a" flags)
        (with-current-buffer (window-buffer win) (auto-revert-mode 1)))
      (when (assoc "f" flags)
        (setq org-win-find-file--focus-window win))
      ;; Size-related options fight `balance-windows', so defer them and
      ;; record the window so it can be pinned while the rest re-balance.
      (when (assoc "F" flags)
        (push win org-win-find-file--sized-windows)
        (push (lambda () (fit-window-to-buffer win))
              org-win-find-file--deferred))
      (let ((size (cdr (assoc "w" flags))))
        (when (stringp size)
          (push win org-win-find-file--sized-windows)
          (push (lambda () (org-win-find-file--apply-size win size))
                org-win-find-file--deferred))))))

(defun org-win-find-file--parse (str)
  "Parse STR into a layout tree.
A leaf is an `org-win-find-file-leaf'.  A split is (DIR . CHILDREN)
where DIR is `v' (stacked) or `h' (side by side) and CHILDREN is a
list of sub-trees."
  (let ((pos 0)
        (len (length str)))
    (cl-labels
        ((peek () (and (< pos len) (aref str pos)))
         (parse-vsplit ()
           (let ((children (list (parse-hsplit))))
             (while (eql (peek) org-win-find-file-vsplit-char)
               (setq pos (1+ pos))
               (push (parse-hsplit) children))
             (if (cdr children)
                 (cons 'v (nreverse children))
               (car children))))
         (parse-hsplit ()
           (let ((children (list (parse-atom))))
             (while (eql (peek) org-win-find-file-hsplit-char)
               (setq pos (1+ pos))
               (push (parse-atom) children))
             (if (cdr children)
                 (cons 'h (nreverse children))
               (car children))))
         (parse-atom ()
           (if (eql (peek) ?\()
               (progn
                 (setq pos (1+ pos))     ; consume "("
                 (let ((node (parse-vsplit)))
                   (unless (eql (peek) ?\))
                     (error "Unbalanced parens in win: link: %s" str))
                   (setq pos (1+ pos))   ; consume ")"
                   node))
             (let ((start pos))
               (while (and (< pos len)
                           (not (memq (aref str pos)
                                      (list org-win-find-file-vsplit-char
                                            org-win-find-file-hsplit-char
                                            org-win-find-file-suffix-open
                                            ?\( ?\)))))
                 (setq pos (1+ pos)))
               (when (= start pos)
                 (error "Empty target in win: link: %s" str))
               (org-win-find-file--make-leaf
                :target (string-trim (substring str start pos))
                :flags (parse-suffix)))))
         (parse-suffix ()
           ;; Read an optional "«...»" suffix and return its options as
           ;; an alist.  Return nil when no suffix is present.
           (when (eql (peek) org-win-find-file-suffix-open)
             (setq pos (1+ pos))         ; consume "«"
             (let ((start pos))
               (while (and (< pos len)
                           (not (eql (aref str pos)
                                     org-win-find-file-suffix-close)))
                 (setq pos (1+ pos)))
               (unless (eql (peek) org-win-find-file-suffix-close)
                 (error "Unterminated suffix in win: link: %s" str))
               (prog1 (org-win-find-file--parse-flags
                       (substring str start pos))
                 (setq pos (1+ pos)))))))   ; consume "»"
      (let ((tree (parse-vsplit)))
        (when (< pos len)
          (error "Trailing characters in win: link: %s" str))
        tree))))

(defun org-win-find-file--make-windows (window n dir)
  "Split WINDOW into N windows in direction DIR.
DIR is `h' (side by side) or `v' (stacked).  Return the list of
windows in visual order (left to right, or top to bottom)."
  (let ((side (if (eq dir 'h) 'right 'below))
        (windows (list window)))
    (dotimes (_ (1- n))
      (let* ((last (car (last windows)))
             (new (split-window last nil side)))
        (setq windows (append windows (list new)))))
    windows))

(defun org-win-find-file--layout (window node)
  "Realize layout NODE inside WINDOW, opening targets when a leaf is reached."
  (if (org-win-find-file-leaf-p node)
      (progn
        (select-window window)
        (org-win-find-file--open-target node))
    (let* ((dir (car node))
           (children (cdr node))
           (windows (org-win-find-file--make-windows
                     window (length children) dir)))
      (cl-loop for child in children
               for win in windows
               do (org-win-find-file--layout win child)))))

(defun org-win-find-file-open (path)
  "Open the targets in PATH in a freshly built window layout.
See the commentary for the PATH syntax (targets joined by \"|\"
and \"÷\", with parentheses for grouping)."
  (let ((tree (org-win-find-file--parse path))
        (org-win-find-file--focus-window nil)
        (org-win-find-file--deferred nil)
        (org-win-find-file--sized-windows nil))
    (delete-other-windows)
    (org-win-find-file--layout (selected-window) tree)
    (balance-windows)
    ;; Size/fit options are applied after balancing, in open order.
    (dolist (thunk (nreverse org-win-find-file--deferred))
      (funcall thunk))
    ;; Pin the explicitly sized windows and re-balance, so their unsized
    ;; siblings share the remaining space evenly (e.g. one window at 50%
    ;; of a three-way split leaves the other two at 25% each) rather than
    ;; the resize stealing space from a single neighbour.
    (when org-win-find-file--sized-windows
      (dolist (win org-win-find-file--sized-windows)
        (when (window-live-p win)
          (org-win-find-file--pin-window-size win)))
      (balance-windows)
      (dolist (win org-win-find-file--sized-windows)
        (when (window-live-p win)
          (with-current-buffer (window-buffer win)
            (kill-local-variable 'window-size-fixed)))))
    (select-window (or org-win-find-file--focus-window
                       (frame-first-window)))))

(provide 'org-win-find-file)
;;; org-win-find-file.el ends here
