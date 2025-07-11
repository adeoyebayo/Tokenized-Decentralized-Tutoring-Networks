;; Payment Processing Contract
;; Manages hourly tutoring fee transactions

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-UNAUTHORIZED (err u400))
(define-constant ERR-NOT-FOUND (err u401))
(define-constant ERR-INVALID-INPUT (err u402))
(define-constant ERR-INSUFFICIENT-FUNDS (err u403))
(define-constant ERR-PAYMENT-LOCKED (err u404))
(define-constant PLATFORM-FEE-RATE u50) ;; 5% platform fee (scaled by 1000)

;; Data Variables
(define-data-var next-payment-id uint u1)
(define-data-var platform-treasury principal CONTRACT-OWNER)
(define-data-var total-platform-fees uint u0)

;; Data Maps
(define-map payments
  { payment-id: uint }
  {
    session-id: uint,
    student-id: uint,
    tutor-id: uint,
    amount: uint,
    platform-fee: uint,
    tutor-amount: uint,
    status: (string-ascii 20),
    escrow-locked: bool,
    created-at: uint,
    released-at: (optional uint),
    disputed-at: (optional uint)
  }
)

(define-map escrow-balances
  { user-id: uint }
  { balance: uint }
)

(define-map payment-disputes
  { payment-id: uint }
  {
    disputer: principal,
    reason: (string-ascii 500),
    status: (string-ascii 20),
    created-at: uint,
    resolved-at: (optional uint),
    resolution: (optional (string-ascii 500))
  }
)

(define-map tutor-earnings
  { tutor-id: uint }
  {
    total-earned: uint,
    total-sessions: uint,
    pending-amount: uint,
    withdrawn-amount: uint
  }
)

(define-map student-payments
  { student-id: uint }
  {
    total-paid: uint,
    total-sessions: uint,
    escrowed-amount: uint
  }
)

;; Public Functions

;; Create payment for session
(define-public (create-payment (session-id uint) (student-id uint) (tutor-id uint) (amount uint))
  (let
    (
      (payment-id (var-get next-payment-id))
      (platform-fee (/ (* amount PLATFORM-FEE-RATE) u1000))
      (tutor-amount (- amount platform-fee))
      (current-block block-height)
    )
    (asserts! (> amount u0) ERR-INVALID-INPUT)

    (map-set payments
      { payment-id: payment-id }
      {
        session-id: session-id,
        student-id: student-id,
        tutor-id: tutor-id,
        amount: amount,
        platform-fee: platform-fee,
        tutor-amount: tutor-amount,
        status: "created",
        escrow-locked: false,
        created-at: current-block,
        released-at: none,
        disputed-at: none
      }
    )

    (var-set next-payment-id (+ payment-id u1))
    (ok payment-id)
  )
)

;; Lock payment in escrow
(define-public (lock-payment-escrow (payment-id uint))
  (let
    (
      (payment-data (unwrap! (map-get? payments { payment-id: payment-id }) ERR-NOT-FOUND))
      (student-id (get student-id payment-data))
      (amount (get amount payment-data))
      (current-balance (default-to u0 (get balance (map-get? escrow-balances { user-id: student-id }))))
    )
    (asserts! (not (get escrow-locked payment-data)) ERR-PAYMENT-LOCKED)
    (asserts! (>= current-balance amount) ERR-INSUFFICIENT-FUNDS)

    ;; Deduct from student balance
    (map-set escrow-balances
      { user-id: student-id }
      { balance: (- current-balance amount) }
    )

    ;; Lock payment
    (map-set payments
      { payment-id: payment-id }
      (merge payment-data {
        status: "escrowed",
        escrow-locked: true
      })
    )

    ;; Update student payment stats
    (update-student-payment-stats student-id amount)

    (ok true)
  )
)

;; Release payment to tutor
(define-public (release-payment (payment-id uint))
  (let
    (
      (payment-data (unwrap! (map-get? payments { payment-id: payment-id }) ERR-NOT-FOUND))
      (tutor-id (get tutor-id payment-data))
      (tutor-amount (get tutor-amount payment-data))
      (platform-fee (get platform-fee payment-data))
      (current-block block-height)
    )
    (asserts! (get escrow-locked payment-data) ERR-INVALID-INPUT)
    (asserts! (is-eq (get status payment-data) "escrowed") ERR-INVALID-INPUT)

    ;; Add to tutor earnings
    (update-tutor-earnings tutor-id tutor-amount)

    ;; Add platform fee to treasury
    (var-set total-platform-fees (+ (var-get total-platform-fees) platform-fee))

    ;; Update payment status
    (map-set payments
      { payment-id: payment-id }
      (merge payment-data {
        status: "released",
        released-at: (some current-block)
      })
    )

    (ok true)
  )
)

;; Deposit funds to escrow
(define-public (deposit-to-escrow (user-id uint) (amount uint))
  (let
    (
      (current-balance (default-to u0 (get balance (map-get? escrow-balances { user-id: user-id }))))
    )
    (asserts! (> amount u0) ERR-INVALID-INPUT)

    ;; In real implementation, would handle STX transfer here
    (map-set escrow-balances
      { user-id: user-id }
      { balance: (+ current-balance amount) }
    )

    (ok true)
  )
)

;; Withdraw from escrow
(define-public (withdraw-from-escrow (user-id uint) (amount uint))
  (let
    (
      (current-balance (default-to u0 (get balance (map-get? escrow-balances { user-id: user-id }))))
    )
    (asserts! (> amount u0) ERR-INVALID-INPUT)
    (asserts! (>= current-balance amount) ERR-INSUFFICIENT-FUNDS)

    (map-set escrow-balances
      { user-id: user-id }
      { balance: (- current-balance amount) }
    )

    ;; In real implementation, would handle STX transfer here
    (ok true)
  )
)

;; Create payment dispute
(define-public (create-dispute (payment-id uint) (reason (string-ascii 500)))
  (let
    (
      (payment-data (unwrap! (map-get? payments { payment-id: payment-id }) ERR-NOT-FOUND))
      (current-block block-height)
    )
    (asserts! (> (len reason) u0) ERR-INVALID-INPUT)
    (asserts! (get escrow-locked payment-data) ERR-INVALID-INPUT)

    (map-set payment-disputes
      { payment-id: payment-id }
      {
        disputer: tx-sender,
        reason: reason,
        status: "open",
        created-at: current-block,
        resolved-at: none,
        resolution: none
      }
    )

    (map-set payments
      { payment-id: payment-id }
      (merge payment-data {
        status: "disputed",
        disputed-at: (some current-block)
      })
    )

    (ok true)
  )
)

;; Resolve dispute
(define-public (resolve-dispute (payment-id uint) (resolution (string-ascii 500)) (refund-to-student bool))
  (let
    (
      (payment-data (unwrap! (map-get? payments { payment-id: payment-id }) ERR-NOT-FOUND))
      (dispute-data (unwrap! (map-get? payment-disputes { payment-id: payment-id }) ERR-NOT-FOUND))
      (current-block block-height)
    )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (is-eq (get status dispute-data) "open") ERR-INVALID-INPUT)

    (if refund-to-student
      ;; Refund to student
      (begin
        (map-set escrow-balances
          { user-id: (get student-id payment-data) }
          { balance: (+ (default-to u0 (get balance (map-get? escrow-balances { user-id: (get student-id payment-data) }))) (get amount payment-data)) }
        )
        (map-set payments
          { payment-id: payment-id }
          (merge payment-data { status: "refunded" })
        )
      )
      ;; Release to tutor
      (try! (release-payment payment-id))
    )

    (map-set payment-disputes
      { payment-id: payment-id }
      (merge dispute-data {
        status: "resolved",
        resolved-at: (some current-block),
        resolution: (some resolution)
      })
    )

    (ok true)
  )
)

;; Read-only Functions

;; Get payment
(define-read-only (get-payment (payment-id uint))
  (map-get? payments { payment-id: payment-id })
)

;; Get escrow balance
(define-read-only (get-escrow-balance (user-id uint))
  (default-to u0 (get balance (map-get? escrow-balances { user-id: user-id })))
)

;; Get payment dispute
(define-read-only (get-dispute (payment-id uint))
  (map-get? payment-disputes { payment-id: payment-id })
)

;; Get tutor earnings
(define-read-only (get-tutor-earnings (tutor-id uint))
  (map-get? tutor-earnings { tutor-id: tutor-id })
)

;; Get student payments
(define-read-only (get-student-payments (student-id uint))
  (map-get? student-payments { student-id: student-id })
)

;; Get platform fees collected
(define-read-only (get-platform-fees)
  (var-get total-platform-fees)
)

;; Private Functions

;; Update tutor earnings
(define-private (update-tutor-earnings (tutor-id uint) (amount uint))
  (let
    (
      (current-earnings (default-to { total-earned: u0, total-sessions: u0, pending-amount: u0, withdrawn-amount: u0 }
                                   (map-get? tutor-earnings { tutor-id: tutor-id })))
    )
    (map-set tutor-earnings
      { tutor-id: tutor-id }
      {
        total-earned: (+ (get total-earned current-earnings) amount),
        total-sessions: (+ (get total-sessions current-earnings) u1),
        pending-amount: (+ (get pending-amount current-earnings) amount),
        withdrawn-amount: (get withdrawn-amount current-earnings)
      }
    )
  )
)

;; Update student payment stats
(define-private (update-student-payment-stats (student-id uint) (amount uint))
  (let
    (
      (current-payments (default-to { total-paid: u0, total-sessions: u0, escrowed-amount: u0 }
                                   (map-get? student-payments { student-id: student-id })))
    )
    (map-set student-payments
      { student-id: student-id }
      {
        total-paid: (+ (get total-paid current-payments) amount),
        total-sessions: (+ (get total-sessions current-payments) u1),
        escrowed-amount: (+ (get escrowed-amount current-payments) amount)
      }
    )
  )
)
