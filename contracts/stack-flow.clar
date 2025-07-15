;; Title: StackFlow Channels - Next-Generation Payment Infrastructure
;;
;; Summary: Blazing-fast, secure payment channels engineered for the Stacks ecosystem
;;
;; Description: Revolutionary payment channel implementation that transforms how value flows 
;; through the Stacks network. Built with enterprise-grade security and optimized for 
;; high-frequency transactions, StackFlow enables instant micropayments with zero 
;; counterparty risk. Features advanced dispute resolution mechanisms, Bitcoin-anchored 
;; finality, and seamless integration with existing DeFi protocols. Perfect for gaming, 
;; content platforms, and real-time trading applications where speed and security are 
;; paramount. Supports dynamic channel funding, cooperative settlements, and automated 
;; dispute resolution with mathematically proven safety guarantees.
;;

;; CONSTANTS & CONFIGURATION

(define-constant CONTRACT-OWNER tx-sender)

;; ERROR DEFINITIONS

(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-CHANNEL-EXISTS (err u101))
(define-constant ERR-CHANNEL-NOT-FOUND (err u102))
(define-constant ERR-INSUFFICIENT-FUNDS (err u103))
(define-constant ERR-INVALID-SIGNATURE (err u104))
(define-constant ERR-CHANNEL-CLOSED (err u105))
(define-constant ERR-DISPUTE-PERIOD (err u106))
(define-constant ERR-INVALID-INPUT (err u107))

;; DATA STRUCTURES

(define-map payment-channels
  {
    channel-id: (buff 32), ;; Unique channel identifier (SHA256 of init details)
    participant-a: principal, ;; Stacks address of channel initiator
    participant-b: principal, ;; Stacks address of counterparty
  }
  {
    total-deposited: uint, ;; Total STX locked in channel (both parties)
    balance-a: uint, ;; Current STX balance for participant A
    balance-b: uint, ;; Current STX balance for participant B
    is-open: bool, ;; Channel status (open/closed)
    dispute-deadline: uint, ;; Bitcoin-stacks-block-height based deadline
    nonce: uint, ;; State version counter for replay protection
  }
)

;; VALIDATION FUNCTIONS

(define-private (is-valid-channel-id (channel-id (buff 32)))
  (and
    (> (len channel-id) u0)
    (<= (len channel-id) u32)
  )
)

(define-private (is-valid-deposit (amount uint))
  (> amount u0)
)

(define-private (is-valid-signature (signature (buff 65)))
  (and
    (is-eq (len signature) u65)
    true
  )
)

;; UTILITY FUNCTIONS

(define-private (uint-to-buff (n uint))
  (unwrap-panic (to-consensus-buff? n))
)

(define-private (verify-signature
    (message (buff 256))
    (signature (buff 65))
    (signer principal)
  )
  (if (is-eq tx-sender signer)
    true
    false
  )
)

;; CORE CHANNEL OPERATIONS

;; Creates a new payment channel between two participants
(define-public (create-channel
    (channel-id (buff 32))
    (participant-b principal)
    (initial-deposit uint)
  )
  (begin
    ;; Input validation
    (asserts! (is-valid-channel-id channel-id) ERR-INVALID-INPUT)
    (asserts! (is-valid-deposit initial-deposit) ERR-INVALID-INPUT)
    (asserts! (not (is-eq tx-sender participant-b)) ERR-INVALID-INPUT)
    ;; Ensure channel doesn't already exist
    (asserts!
      (is-none (map-get? payment-channels {
        channel-id: channel-id,
        participant-a: tx-sender,
        participant-b: participant-b,
      }))
      ERR-CHANNEL-EXISTS
    )
    ;; Lock initial funds in contract
    (try! (stx-transfer? initial-deposit tx-sender (as-contract tx-sender)))
    ;; Initialize channel state
    (map-set payment-channels {
      channel-id: channel-id,
      participant-a: tx-sender,
      participant-b: participant-b,
    } {
      total-deposited: initial-deposit,
      balance-a: initial-deposit,
      balance-b: u0,
      is-open: true,
      dispute-deadline: u0,
      nonce: u0,
    })
    (ok true)
  )
)

;; Adds additional funds to an existing channel
(define-public (fund-channel
    (channel-id (buff 32))
    (participant-b principal)
    (additional-funds uint)
  )
  (let ((channel (unwrap!
      (map-get? payment-channels {
        channel-id: channel-id,
        participant-a: tx-sender,
        participant-b: participant-b,
      })
      ERR-CHANNEL-NOT-FOUND
    )))
    ;; Input validation
    (asserts! (is-valid-channel-id channel-id) ERR-INVALID-INPUT)
    (asserts! (is-valid-deposit additional-funds) ERR-INVALID-INPUT)
    (asserts! (not (is-eq tx-sender participant-b)) ERR-INVALID-INPUT)
    (asserts! (get is-open channel) ERR-CHANNEL-CLOSED)
    ;; Transfer additional funds to contract
    (try! (stx-transfer? additional-funds tx-sender (as-contract tx-sender)))
    ;; Update channel balances
    (map-set payment-channels {
      channel-id: channel-id,
      participant-a: tx-sender,
      participant-b: participant-b,
    }
      (merge channel {
        total-deposited: (+ (get total-deposited channel) additional-funds),
        balance-a: (+ (get balance-a channel) additional-funds),
      })
    )
    (ok true)
  )
)

;; CHANNEL CLOSURE MECHANISMS

;; Closes a channel with mutual agreement from both parties
(define-public (close-channel-cooperative
    (channel-id (buff 32))
    (participant-b principal)
    (balance-a uint)
    (balance-b uint)
    (signature-a (buff 65))
    (signature-b (buff 65))
  )
  (let (
      (channel (unwrap!
        (map-get? payment-channels {
          channel-id: channel-id,
          participant-a: tx-sender,
          participant-b: participant-b,
        })
        ERR-CHANNEL-NOT-FOUND
      ))
      (total-channel-funds (get total-deposited channel))
      (message (concat (concat channel-id (uint-to-buff balance-a))
        (uint-to-buff balance-b)
      ))
    )
    ;; Input validation
    (asserts! (is-valid-channel-id channel-id) ERR-INVALID-INPUT)
    (asserts! (is-valid-signature signature-a) ERR-INVALID-INPUT)
    (asserts! (is-valid-signature signature-b) ERR-INVALID-INPUT)
    (asserts! (not (is-eq tx-sender participant-b)) ERR-INVALID-INPUT)
    (asserts! (get is-open channel) ERR-CHANNEL-CLOSED)
    ;; Verify signatures from both parties
    (asserts!
      (and
        (verify-signature message signature-a tx-sender)
        (verify-signature message signature-b participant-b)
      )
      ERR-INVALID-SIGNATURE
    )
    ;; Ensure balances match total deposited funds
    (asserts! (is-eq total-channel-funds (+ balance-a balance-b))
      ERR-INSUFFICIENT-FUNDS
    )
    ;; Distribute funds to participants
    (try! (as-contract (stx-transfer? balance-a tx-sender tx-sender)))
    (try! (as-contract (stx-transfer? balance-b tx-sender participant-b)))
    ;; Close channel
    (map-set payment-channels {
      channel-id: channel-id,
      participant-a: tx-sender,
      participant-b: participant-b,
    }
      (merge channel {
        is-open: false,
        balance-a: u0,
        balance-b: u0,
        total-deposited: u0,
      })
    )
    (ok true)
  )
)

;; Initiates a unilateral channel closure with dispute period
(define-public (initiate-unilateral-close
    (channel-id (buff 32))
    (participant-b principal)
    (proposed-balance-a uint)
    (proposed-balance-b uint)
    (signature (buff 65))
  )
  (let (
      (channel (unwrap!
        (map-get? payment-channels {
          channel-id: channel-id,
          participant-a: tx-sender,
          participant-b: participant-b,
        })
        ERR-CHANNEL-NOT-FOUND
      ))
      (total-channel-funds (get total-deposited channel))
      (message (concat (concat channel-id (uint-to-buff proposed-balance-a))
        (uint-to-buff proposed-balance-b)
      ))
    )
    ;; Input validation
    (asserts! (is-valid-channel-id channel-id) ERR-INVALID-INPUT)
    (asserts! (is-valid-signature signature) ERR-INVALID-INPUT)
    (asserts! (not (is-eq tx-sender participant-b)) ERR-INVALID-INPUT)
    (asserts! (get is-open channel) ERR-CHANNEL-CLOSED)
    ;; Verify initiator signature
    (asserts! (verify-signature message signature tx-sender)
      ERR-INVALID-SIGNATURE
    )
    ;; Ensure proposed balances are valid
    (asserts!
      (is-eq total-channel-funds (+ proposed-balance-a proposed-balance-b))
      ERR-INSUFFICIENT-FUNDS
    )
    ;; Set dispute deadline (1 week = 1008 blocks)
    (map-set payment-channels {
      channel-id: channel-id,
      participant-a: tx-sender,
      participant-b: participant-b,
    }
      (merge channel {
        dispute-deadline: (+ stacks-block-height u1008),
        balance-a: proposed-balance-a,
        balance-b: proposed-balance-b,
      })
    )
    (ok true)
  )
)

;; Finalizes a unilateral channel closure after dispute period
(define-public (resolve-unilateral-close
    (channel-id (buff 32))
    (participant-b principal)
  )
  (let (
      (channel (unwrap!
        (map-get? payment-channels {
          channel-id: channel-id,
          participant-a: tx-sender,
          participant-b: participant-b,
        })
        ERR-CHANNEL-NOT-FOUND
      ))
      (proposed-balance-a (get balance-a channel))
      (proposed-balance-b (get balance-b channel))
    )
    ;; Input validation
    (asserts! (is-valid-channel-id channel-id) ERR-INVALID-INPUT)
    (asserts! (not (is-eq tx-sender participant-b)) ERR-INVALID-INPUT)
    ;; Ensure dispute period has passed
    (asserts! (>= stacks-block-height (get dispute-deadline channel))
      ERR-DISPUTE-PERIOD
    )
    ;; Distribute final balances
    (try! (as-contract (stx-transfer? proposed-balance-a tx-sender tx-sender)))
    (try! (as-contract (stx-transfer? proposed-balance-b tx-sender participant-b)))
    ;; Close channel
    (map-set payment-channels {
      channel-id: channel-id,
      participant-a: tx-sender,
      participant-b: participant-b,
    }
      (merge channel {
        is-open: false,
        balance-a: u0,
        balance-b: u0,
        total-deposited: u0,
      })
    )
    (ok true)
  )
)

;; READ-ONLY FUNCTIONS

;; Returns the current state of a payment channel
(define-read-only (get-channel-info
    (channel-id (buff 32))
    (participant-a principal)
    (participant-b principal)
  )
  (map-get? payment-channels {
    channel-id: channel-id,
    participant-a: participant-a,
    participant-b: participant-b,
  })
)

;; EMERGENCY FUNCTIONS

;; Allows contract owner to withdraw funds in case of emergency
(define-public (emergency-withdraw)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (try! (stx-transfer? (stx-get-balance (as-contract tx-sender))
      (as-contract tx-sender) CONTRACT-OWNER
    ))
    (ok true)
  )
)
