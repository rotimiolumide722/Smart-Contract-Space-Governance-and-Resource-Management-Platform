;; Asteroid Mining Rights Contract
;; Allocates space resource extraction rights fairly among nations and companies

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-INVALID-INPUT (err u201))
(define-constant ERR-INSUFFICIENT-FUNDS (err u202))
(define-constant ERR-ASTEROID-NOT-FOUND (err u203))
(define-constant ERR-RIGHTS-ALREADY-CLAIMED (err u204))
(define-constant ERR-AUCTION-NOT-ACTIVE (err u205))
(define-constant ERR-BID-TOO-LOW (err u206))

;; Data Variables
(define-data-var next-asteroid-id uint u1)
(define-data-var next-auction-id uint u1)
(define-data-var revenue-sharing-rate uint u10) ;; 10% to global fund
(define-data-var minimum-stake-amount uint u10000)

;; Data Maps
(define-map asteroid-registry
  { asteroid-id: uint }
  {
    name: (string-ascii 50),
    orbital-distance: uint, ;; AU * 1000
    estimated-resources: (string-ascii 200),
    resource-value: uint,
    discovery-date: uint,
    discoverer: principal,
    environmental-impact-score: uint, ;; 1-10 scale
    is-protected: bool
  }
)

(define-map mining-rights
  { asteroid-id: uint }
  {
    rights-holder: principal,
    extraction-limit: uint, ;; percentage of total resources
    expiration-block: uint,
    revenue-sharing-agreement: uint,
    environmental-bond: uint,
    compliance-status: (string-ascii 20)
  }
)

(define-map mining-auctions
  { auction-id: uint }
  {
    asteroid-id: uint,
    starting-bid: uint,
    current-highest-bid: uint,
    highest-bidder: (optional principal),
    auction-end-block: uint,
    extraction-percentage: uint,
    duration-blocks: uint,
    status: (string-ascii 20) ;; "active", "completed", "cancelled"
  }
)

(define-map entity-stakes
  { entity: principal }
  { staked-amount: uint, reputation-score: uint }
)

(define-map authorized-assessors
  { assessor: principal }
  { is-authorized: bool, assessment-count: uint }
)

;; Authorization Functions
(define-public (authorize-assessor (assessor principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (map-set authorized-assessors
         { assessor: assessor }
         { is-authorized: true, assessment-count: u0 }))
  )
)

(define-public (stake-tokens (amount uint))
  (let
    (
      (current-stake (default-to { staked-amount: u0, reputation-score: u50 }
                      (map-get? entity-stakes { entity: tx-sender })))
    )
    (asserts! (>= amount (var-get minimum-stake-amount)) ERR-INSUFFICIENT-FUNDS)

    (map-set entity-stakes
      { entity: tx-sender }
      {
        staked-amount: (+ (get staked-amount current-stake) amount),
        reputation-score: (get reputation-score current-stake)
      }
    )
    (ok true)
  )
)

;; Asteroid Registration Functions
(define-public (register-asteroid
  (name (string-ascii 50))
  (orbital-distance uint)
  (estimated-resources (string-ascii 200))
  (resource-value uint)
  (environmental-impact-score uint))
  (let
    (
      (asteroid-id (var-get next-asteroid-id))
      (assessor-data (default-to { is-authorized: false, assessment-count: u0 }
                      (map-get? authorized-assessors { assessor: tx-sender })))
    )
    (asserts! (get is-authorized assessor-data) ERR-NOT-AUTHORIZED)
    (asserts! (and (>= environmental-impact-score u1) (<= environmental-impact-score u10)) ERR-INVALID-INPUT)
    (asserts! (> resource-value u0) ERR-INVALID-INPUT)

    (map-set asteroid-registry
      { asteroid-id: asteroid-id }
      {
        name: name,
        orbital-distance: orbital-distance,
        estimated-resources: estimated-resources,
        resource-value: resource-value,
        discovery-date: block-height,
        discoverer: tx-sender,
        environmental-impact-score: environmental-impact-score,
        is-protected: (>= environmental-impact-score u8)
      }
    )

    ;; Update assessor count
    (map-set authorized-assessors
      { assessor: tx-sender }
      (merge assessor-data { assessment-count: (+ (get assessment-count assessor-data) u1) })
    )

    (var-set next-asteroid-id (+ asteroid-id u1))
    (ok asteroid-id)
  )
)

;; Auction Functions
(define-public (create-mining-auction
  (asteroid-id uint)
  (starting-bid uint)
  (extraction-percentage uint)
  (duration-blocks uint)
  (auction-duration-blocks uint))
  (let
    (
      (auction-id (var-get next-auction-id))
      (asteroid-data (unwrap! (map-get? asteroid-registry { asteroid-id: asteroid-id }) ERR-ASTEROID-NOT-FOUND))
    )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (not (get is-protected asteroid-data)) ERR-NOT-AUTHORIZED)
    (asserts! (and (> extraction-percentage u0) (<= extraction-percentage u100)) ERR-INVALID-INPUT)
    (asserts! (is-none (map-get? mining-rights { asteroid-id: asteroid-id })) ERR-RIGHTS-ALREADY-CLAIMED)

    (map-set mining-auctions
      { auction-id: auction-id }
      {
        asteroid-id: asteroid-id,
        starting-bid: starting-bid,
        current-highest-bid: starting-bid,
        highest-bidder: none,
        auction-end-block: (+ block-height auction-duration-blocks),
        extraction-percentage: extraction-percentage,
        duration-blocks: duration-blocks,
        status: "active"
      }
    )

    (var-set next-auction-id (+ auction-id u1))
    (ok auction-id)
  )
)

(define-public (place-bid (auction-id uint) (bid-amount uint))
  (let
    (
      (auction-data (unwrap! (map-get? mining-auctions { auction-id: auction-id }) ERR-AUCTION-NOT-ACTIVE))
      (stake-data (unwrap! (map-get? entity-stakes { entity: tx-sender }) ERR-INSUFFICIENT-FUNDS))
    )
    (asserts! (is-eq (get status auction-data) "active") ERR-AUCTION-NOT-ACTIVE)
    (asserts! (< block-height (get auction-end-block auction-data)) ERR-AUCTION-NOT-ACTIVE)
    (asserts! (> bid-amount (get current-highest-bid auction-data)) ERR-BID-TOO-LOW)
    (asserts! (>= (get staked-amount stake-data) (var-get minimum-stake-amount)) ERR-INSUFFICIENT-FUNDS)

    (map-set mining-auctions
      { auction-id: auction-id }
      (merge auction-data {
        current-highest-bid: bid-amount,
        highest-bidder: (some tx-sender)
      })
    )
    (ok true)
  )
)

(define-public (finalize-auction (auction-id uint))
  (let
    (
      (auction-data (unwrap! (map-get? mining-auctions { auction-id: auction-id }) ERR-AUCTION-NOT-ACTIVE))
    )
    (asserts! (>= block-height (get auction-end-block auction-data)) ERR-AUCTION-NOT-ACTIVE)
    (asserts! (is-eq (get status auction-data) "active") ERR-AUCTION-NOT-ACTIVE)

    (match (get highest-bidder auction-data)
      winner (begin
        ;; Grant mining rights
        (map-set mining-rights
          { asteroid-id: (get asteroid-id auction-data) }
          {
            rights-holder: winner,
            extraction-limit: (get extraction-percentage auction-data),
            expiration-block: (+ block-height (get duration-blocks auction-data)),
            revenue-sharing-agreement: (var-get revenue-sharing-rate),
            environmental-bond: (/ (get current-highest-bid auction-data) u10),
            compliance-status: "active"
          }
        )

        ;; Mark auction as completed
        (map-set mining-auctions
          { auction-id: auction-id }
          (merge auction-data { status: "completed" })
        )
        (ok winner)
      )
      ;; No bidders
      (begin
        (map-set mining-auctions
          { auction-id: auction-id }
          (merge auction-data { status: "cancelled" })
        )
        (ok tx-sender)
      )
    )
  )
)

;; Compliance Functions
(define-public (report-extraction (asteroid-id uint) (extracted-amount uint))
  (let
    (
      (rights-data (unwrap! (map-get? mining-rights { asteroid-id: asteroid-id }) ERR-ASTEROID-NOT-FOUND))
    )
    (asserts! (is-eq (get rights-holder rights-data) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (< block-height (get expiration-block rights-data)) ERR-NOT-AUTHORIZED)

    ;; Here would be logic to track extraction amounts and compliance
    (ok true)
  )
)

;; Read-only Functions
(define-read-only (get-asteroid-info (asteroid-id uint))
  (map-get? asteroid-registry { asteroid-id: asteroid-id })
)

(define-read-only (get-mining-rights (asteroid-id uint))
  (map-get? mining-rights { asteroid-id: asteroid-id })
)

(define-read-only (get-auction-info (auction-id uint))
  (map-get? mining-auctions { auction-id: auction-id })
)

(define-read-only (get-entity-stake (entity principal))
  (map-get? entity-stakes { entity: entity })
)
