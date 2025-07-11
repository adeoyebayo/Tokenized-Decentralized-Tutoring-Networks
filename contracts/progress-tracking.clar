;; Progress Tracking Contract
;; Monitors academic improvement and learning outcomes

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-UNAUTHORIZED (err u200))
(define-constant ERR-NOT-FOUND (err u201))
(define-constant ERR-INVALID-INPUT (err u202))

;; Data Variables
(define-data-var next-progress-id uint u1)
(define-data-var next-milestone-id uint u1)

;; Data Maps
(define-map progress-records
  { progress-id: uint }
  {
    student-id: uint,
    tutor-id: uint,
    subject: (string-ascii 30),
    session-count: uint,
    total-hours: uint,
    initial-score: uint,
    current-score: uint,
    improvement-rate: uint,
    created-at: uint,
    updated-at: uint
  }
)

(define-map milestones
  { milestone-id: uint }
  {
    progress-id: uint,
    title: (string-ascii 100),
    description: (string-ascii 500),
    target-score: uint,
    achieved-score: (optional uint),
    is-completed: bool,
    completed-at: (optional uint),
    created-at: uint
  }
)

(define-map session-logs
  { session-id: uint }
  {
    progress-id: uint,
    duration-minutes: uint,
    topics-covered: (list 5 (string-ascii 50)),
    pre-session-score: uint,
    post-session-score: uint,
    notes: (string-ascii 1000),
    logged-at: uint
  }
)

(define-map student-progress
  { student-id: uint, subject: (string-ascii 30) }
  { progress-id: uint }
)

;; Public Functions

;; Initialize progress tracking for a student-tutor pair
(define-public (initialize-progress (student-id uint) (tutor-id uint) (subject (string-ascii 30)) (initial-score uint))
  (let
    (
      (progress-id (var-get next-progress-id))
      (current-block block-height)
    )
    (asserts! (> (len subject) u0) ERR-INVALID-INPUT)
    (asserts! (<= initial-score u1000) ERR-INVALID-INPUT) ;; Score out of 1000

    (map-set progress-records
      { progress-id: progress-id }
      {
        student-id: student-id,
        tutor-id: tutor-id,
        subject: subject,
        session-count: u0,
        total-hours: u0,
        initial-score: initial-score,
        current-score: initial-score,
        improvement-rate: u0,
        created-at: current-block,
        updated-at: current-block
      }
    )

    (map-set student-progress
      { student-id: student-id, subject: subject }
      { progress-id: progress-id }
    )

    (var-set next-progress-id (+ progress-id u1))
    (ok progress-id)
  )
)

;; Log a tutoring session
(define-public (log-session (progress-id uint) (session-id uint) (duration-minutes uint) (topics-covered (list 5 (string-ascii 50))) (pre-score uint) (post-score uint) (notes (string-ascii 1000)))
  (let
    (
      (progress-data (unwrap! (map-get? progress-records { progress-id: progress-id }) ERR-NOT-FOUND))
      (current-block block-height)
      (new-session-count (+ (get session-count progress-data) u1))
      (new-total-hours (+ (get total-hours progress-data) (/ duration-minutes u60)))
      (improvement (if (> post-score pre-score) (- post-score pre-score) u0))
    )
    (asserts! (> duration-minutes u0) ERR-INVALID-INPUT)
    (asserts! (<= pre-score u1000) ERR-INVALID-INPUT)
    (asserts! (<= post-score u1000) ERR-INVALID-INPUT)

    ;; Log the session
    (map-set session-logs
      { session-id: session-id }
      {
        progress-id: progress-id,
        duration-minutes: duration-minutes,
        topics-covered: topics-covered,
        pre-session-score: pre-score,
        post-session-score: post-score,
        notes: notes,
        logged-at: current-block
      }
    )

    ;; Update progress record
    (map-set progress-records
      { progress-id: progress-id }
      (merge progress-data {
        session-count: new-session-count,
        total-hours: new-total-hours,
        current-score: post-score,
        improvement-rate: (calculate-improvement-rate (get initial-score progress-data) post-score new-session-count),
        updated-at: current-block
      })
    )

    (ok true)
  )
)

;; Create a milestone
(define-public (create-milestone (progress-id uint) (title (string-ascii 100)) (description (string-ascii 500)) (target-score uint))
  (let
    (
      (milestone-id (var-get next-milestone-id))
      (current-block block-height)
    )
    (asserts! (is-some (map-get? progress-records { progress-id: progress-id })) ERR-NOT-FOUND)
    (asserts! (> (len title) u0) ERR-INVALID-INPUT)
    (asserts! (<= target-score u1000) ERR-INVALID-INPUT)

    (map-set milestones
      { milestone-id: milestone-id }
      {
        progress-id: progress-id,
        title: title,
        description: description,
        target-score: target-score,
        achieved-score: none,
        is-completed: false,
        completed-at: none,
        created-at: current-block
      }
    )

    (var-set next-milestone-id (+ milestone-id u1))
    (ok milestone-id)
  )
)

;; Complete a milestone
(define-public (complete-milestone (milestone-id uint) (achieved-score uint))
  (let
    (
      (milestone-data (unwrap! (map-get? milestones { milestone-id: milestone-id }) ERR-NOT-FOUND))
      (current-block block-height)
    )
    (asserts! (not (get is-completed milestone-data)) ERR-INVALID-INPUT)
    (asserts! (>= achieved-score (get target-score milestone-data)) ERR-INVALID-INPUT)
    (asserts! (<= achieved-score u1000) ERR-INVALID-INPUT)

    (map-set milestones
      { milestone-id: milestone-id }
      (merge milestone-data {
        achieved-score: (some achieved-score),
        is-completed: true,
        completed-at: (some current-block)
      })
    )

    (ok true)
  )
)

;; Update progress score
(define-public (update-progress-score (progress-id uint) (new-score uint))
  (let
    (
      (progress-data (unwrap! (map-get? progress-records { progress-id: progress-id }) ERR-NOT-FOUND))
      (current-block block-height)
    )
    (asserts! (<= new-score u1000) ERR-INVALID-INPUT)

    (map-set progress-records
      { progress-id: progress-id }
      (merge progress-data {
        current-score: new-score,
        improvement-rate: (calculate-improvement-rate (get initial-score progress-data) new-score (get session-count progress-data)),
        updated-at: current-block
      })
    )

    (ok true)
  )
)

;; Read-only Functions

;; Get progress record
(define-read-only (get-progress (progress-id uint))
  (map-get? progress-records { progress-id: progress-id })
)

;; Get milestone
(define-read-only (get-milestone (milestone-id uint))
  (map-get? milestones { milestone-id: milestone-id })
)

;; Get session log
(define-read-only (get-session-log (session-id uint))
  (map-get? session-logs { session-id: session-id })
)

;; Get student progress for subject
(define-read-only (get-student-progress (student-id uint) (subject (string-ascii 30)))
  (match (map-get? student-progress { student-id: student-id, subject: subject })
    progress-ref (map-get? progress-records { progress-id: (get progress-id progress-ref) })
    none
  )
)

;; Calculate improvement percentage
(define-read-only (calculate-improvement-percentage (progress-id uint))
  (match (map-get? progress-records { progress-id: progress-id })
    progress-data
      (let
        (
          (initial (get initial-score progress-data))
          (current (get current-score progress-data))
        )
        (if (> initial u0)
          (some (/ (* (- current initial) u100) initial))
          none
        )
      )
    none
  )
)

;; Private Functions

;; Calculate improvement rate (score improvement per session)
(define-private (calculate-improvement-rate (initial-score uint) (current-score uint) (session-count uint))
  (if (and (> session-count u0) (> current-score initial-score))
    (/ (- current-score initial-score) session-count)
    u0
  )
)
