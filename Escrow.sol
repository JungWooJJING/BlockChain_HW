// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Escrow {
    // 거래 상태를 나타내는 enum
    enum State {
        None,       // 존재하지 않는 거래
        Created,    // 판매자가 거래를 생성한 상태
        Funded,     // 구매자가 이더를 예치한 상태
        Shipped,    // 판매자가 배송 처리한 상태
        Released,   // 판매자에게 금액이 지급된 상태
        Refunded,   // 구매자에게 환불된 상태
        Cancelled   // 거래가 취소된 상태
    }

    // 개별 거래 정보를 저장하는 구조체
    struct Deal {
        address seller;                 // 판매자 주소
        address buyer;                  // 구매자 주소
        uint256 amount;                 // 거래 금액 (wei)
        bytes32 secretHash;             // 구매자가 설정한 secret hash
        string  itemDescription;        // 상품 설명
        uint256 shipTimeout;            // 배송까지 허용되는 시간
        uint256 receiveTimeout;         // 수령 확인까지 허용되는 시간
        uint256 shipDeadline;           // 배송 마감 시간
        uint256 receiveDeadline;        // 수령 확인 마감 시간
        State   state;                  // 현재 거래 상태
        bool    sellerCancelRequested;  // 판매자의 취소 요청 여부
        bool    buyerCancelRequested;   // 구매자의 취소 요청 여부
    }

    // 다음 거래 ID
    uint256 public nextDealId;

    // dealId를 기준으로 거래 정보를 저장 (자동 getter 비활성화 - getDeal 사용)
    mapping(uint256 => Deal) internal deals;

    // 사용자 주소별로 참여한 거래 ID 목록 저장
    mapping(address => uint256[]) public dealsByUser;

    // 기본 timeout 값
    uint256 public constant DEFAULT_SHIP_TIMEOUT    = 7 days;
    uint256 public constant DEFAULT_RECEIVE_TIMEOUT = 7 days;

    // timeout 최소/최대 제한
    uint256 public constant MIN_TIMEOUT             = 1 hours;
    uint256 public constant MAX_TIMEOUT             = 90 days;

    // reentrancy 방지를 위한 lock 변수
    uint256 private _locked = 1;

    event DealCreated(uint256 indexed dealId, address indexed seller, uint256 amount, string itemDescription);
    event DealFunded(uint256 indexed dealId, address indexed buyer, bytes32 secretHash);
    event DealShipped(uint256 indexed dealId);
    event DealReleased(uint256 indexed dealId, address indexed seller, uint256 amount, string reason);
    event DealRefunded(uint256 indexed dealId, address indexed buyer, uint256 amount, string reason);
    event DealCancelled(uint256 indexed dealId);
    event CancelRequested(uint256 indexed dealId, address indexed by);

    // 판매자만 호출할 수 있도록 제한
    modifier onlySeller(uint256 dealId) {
        require(msg.sender == deals[dealId].seller, "not seller");
        _;
    }

    // 구매자만 호출할 수 있도록 제한
    modifier onlyBuyer(uint256 dealId) {
        require(msg.sender == deals[dealId].buyer, "not buyer");
        _;
    }

    // 재진입 공격 방지용 modifier
    modifier nonReentrant() {
        require(_locked == 1, "reentrant");
        _locked = 2;
        _;
        _locked = 1;
    }

    // 거래와 무관하게 직접 송금되는 ETH는 거부 (depositWithSecret 외 경로 차단)
    receive() external payable {
        revert("ETH not accepted");
    }

    // 지원하지 않는 함수 호출도 거부
    fallback() external payable {
        revert("not supported");
    }

    // 판매자가 새로운 거래를 생성하는 함수
    function createDeal(
        uint256 amount,
        string calldata itemDescription,
        uint256 shipTimeoutSec,
        uint256 receiveTimeoutSec
    ) external returns (uint256 dealId) {
        require(amount > 0, "amount = 0");
        require(bytes(itemDescription).length > 0, "empty desc");
        require(bytes(itemDescription).length <= 256, "desc too long");

        // timeout 값이 0이면 기본값을 사용
        uint256 shipT    = shipTimeoutSec    == 0 ? DEFAULT_SHIP_TIMEOUT    : shipTimeoutSec;
        uint256 receiveT = receiveTimeoutSec == 0 ? DEFAULT_RECEIVE_TIMEOUT : receiveTimeoutSec;

        // 너무 짧거나 긴 timeout은 허용하지 않음
        require(shipT    >= MIN_TIMEOUT && shipT    <= MAX_TIMEOUT, "ship timeout range");
        require(receiveT >= MIN_TIMEOUT && receiveT <= MAX_TIMEOUT, "recv timeout range");

        // 새로운 dealId 발급
        dealId = ++nextDealId;

        // 거래 정보 저장
        Deal storage d = deals[dealId];
        d.seller          = msg.sender;
        d.amount          = amount;
        d.itemDescription = itemDescription;
        d.shipTimeout     = shipT;
        d.receiveTimeout  = receiveT;
        d.state           = State.Created;

        // 판매자의 거래 목록에 추가
        dealsByUser[msg.sender].push(dealId);

        emit DealCreated(dealId, msg.sender, amount, itemDescription);
    }

    // 구매자가 secret hash를 등록하고 이더를 예치하는 함수
    function depositWithSecret(uint256 dealId, bytes32 secretHash)
        external
        payable
        nonReentrant
    {
        Deal storage d = deals[dealId];

        require(d.state == State.Created, "not in Created");
        require(msg.sender != d.seller, "seller cannot buy");
        require(secretHash != bytes32(0), "empty secret hash");
        require(msg.value == d.amount, "wrong eth amount");

        // 구매자 정보와 secret hash 저장
        d.buyer        = msg.sender;
        d.secretHash   = secretHash;
        d.shipDeadline = block.timestamp + d.shipTimeout;
        d.state        = State.Funded;

        // 구매자의 거래 목록에 추가
        dealsByUser[msg.sender].push(dealId);

        emit DealFunded(dealId, msg.sender, secretHash);
    }

    // 판매자가 배송 완료 상태로 변경하는 함수
    function markShipped(uint256 dealId) external onlySeller(dealId) {
        Deal storage d = deals[dealId];

        require(d.state == State.Funded, "not Funded");

        d.state           = State.Shipped;
        d.receiveDeadline = block.timestamp + d.receiveTimeout;

        emit DealShipped(dealId);
    }

    // 판매자가 secret을 제출하여 예치금을 수령하는 함수
    function release(uint256 dealId, string calldata secret, bytes32 salt)
        external
        onlySeller(dealId)
        nonReentrant
    {
        Deal storage d = deals[dealId];

        require(
            d.state == State.Shipped || d.state == State.Funded,
            "wrong state"
        );

        // 구매자가 등록한 secretHash와 판매자가 제출한 secret + salt가 맞는지 검증
        require(
            keccak256(abi.encodePacked(secret, salt)) == d.secretHash,
            "secret mismatch"
        );

        // 상태를 먼저 변경한 뒤 송금
        d.state = State.Released;

        _send(d.seller, d.amount);

        emit DealReleased(dealId, d.seller, d.amount, "secret-verified");
    }

    // 판매자가 배송 기한을 넘겼을 때 구매자가 환불받는 함수
    function refundIfShipTimeout(uint256 dealId)
        external
        onlyBuyer(dealId)
        nonReentrant
    {
        Deal storage d = deals[dealId];

        require(d.state == State.Funded, "not Funded");
        require(block.timestamp > d.shipDeadline, "before deadline");

        _refund(dealId, "ship-timeout");
    }

    // 구매자가 수령 확인을 하지 않고 시간이 지난 경우 판매자가 금액을 수령하는 함수
    function claimAfterReceiveTimeout(uint256 dealId)
        external
        onlySeller(dealId)
        nonReentrant
    {
        Deal storage d = deals[dealId];

        require(d.state == State.Shipped, "not Shipped");
        require(block.timestamp > d.receiveDeadline, "before deadline");

        d.state = State.Released;

        _send(d.seller, d.amount);

        emit DealReleased(dealId, d.seller, d.amount, "receive-timeout");
    }

    // 평문/salt 분실 시 구매자가 직접 수령 확인하여 판매자에게 송금
    function confirmReceipt(uint256 dealId)
        external
        onlyBuyer(dealId)
        nonReentrant
    {
        Deal storage d = deals[dealId];

        require(
            d.state == State.Funded || d.state == State.Shipped,
            "wrong state"
        );

        d.state = State.Released;

        _send(d.seller, d.amount);

        emit DealReleased(dealId, d.seller, d.amount, "buyer-confirmed");
    }

    // 양측 합의 취소 / 입금 전 판매자 단독 취소
    function requestCancel(uint256 dealId) external nonReentrant {
        Deal storage d = deals[dealId];

        require(
            d.state == State.Created ||
            d.state == State.Funded  ||
            d.state == State.Shipped,
            "not cancellable"
        );

        if (msg.sender == d.seller) {
            d.sellerCancelRequested = true;
        } else if (msg.sender == d.buyer) {
            d.buyerCancelRequested = true;
        } else {
            revert("not party");
        }

        emit CancelRequested(dealId, msg.sender);

        // 입금 전 (Created): 판매자 단독 취소 허용
        if (d.state == State.Created && d.sellerCancelRequested) {
            d.state = State.Cancelled;
            emit DealCancelled(dealId);
            return;
        }

        // 양측 모두 취소 요청 -> 환불
        if (d.sellerCancelRequested && d.buyerCancelRequested) {
            _refund(dealId, "mutual-cancel");
        }
    }

    // 환불 처리 내부 함수
    function _refund(uint256 dealId, string memory reason) internal {
        Deal storage d = deals[dealId];

        d.state = State.Refunded;

        _send(d.buyer, d.amount);

        emit DealRefunded(dealId, d.buyer, d.amount, reason);
    }

    // ETH 송금 내부 함수 (call 사용으로 가스 한도 문제 회피)
    function _send(address to, uint256 amount) internal {
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "eth transfer failed");
    }

    // 거래 정보 조회
    function getDeal(uint256 dealId) external view returns (Deal memory) {
        return deals[dealId];
    }

    // 사용자 거래 목록 조회
    function getUserDeals(address user) external view returns (uint256[] memory) {
        return dealsByUser[user];
    }

    // secret 해시 계산 헬퍼 (오프체인에서도 동일한 결과)
    function computeSecretHash(string calldata secret, bytes32 salt)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(secret, salt));
    }
}
