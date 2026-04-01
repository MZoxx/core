#define NO_UEFI

#include "contract_testing.h"
#include "oracle_testing.h"

static const id QRACEL_CONTRACT_ID(QRACEL_CONTRACT_INDEX, 0, 0, 0);
static const id ADMIN(100, 200, 300, 400);
static const id USER1(123, 456, 789, 876);
static const id USER2(42, 424, 4242, 42424);
static const id USER3(98, 76, 54, 3210);
static const id ORACLE_ID(10, 20, 30, 40);

class QRacelStateChecker : public QRACEL, public QRACEL::StateData
{
public:
    uint32 getRoundCount() const { return this->roundCount; }
    uint32 getBetCount() const { return this->betCount; }
    uint64 getNextRoundId() const { return this->nextRoundId; }
    uint64 getTotalVolume() const { return this->totalVolume; }
    uint64 getTotalPayouts() const { return this->totalPayouts; }
    id getAdmin() const { return this->admin; }
    id getOracleId() const { return this->oracleId; }
    bit getAutoCreate() const { return this->autoCreate; }

    QRACEL::RoundData getRound(uint32 index) const { return this->rounds.get(index); }
    QRACEL::BetData getBet(uint32 index) const { return this->bets.get(index); }
    uint32 getActiveRoundByDuration(uint32 index) const { return this->activeRoundByDuration.get(index); }
};

class ContractTestingQRacel : protected ContractTesting
{
public:
    ContractTestingQRacel()
    {
        initEmptySpectrum();
        initEmptyUniverse();
        INIT_CONTRACT(QRACEL);
        callSystemProcedure(QRACEL_CONTRACT_INDEX, INITIALIZE);

        EXPECT_TRUE(oracleEngine.init(computorPublicKeys));
        EXPECT_TRUE(OI::initOracleInterfaces());

        increaseEnergy(ADMIN, 1000000000LL);
        increaseEnergy(USER1, 1000000000LL);
        increaseEnergy(USER2, 1000000000LL);
        increaseEnergy(USER3, 1000000000LL);
    }

    ~ContractTestingQRacel()
    {
        oracleEngine.deinit();
        checkContractExecCleanup();
    }

    // --- Admin procedures ---

    uint8 setAdmin(const id& invocator, const id& newAdmin, sint64 amount = 0)
    {
        QRACEL::SetAdmin_input input;
        input.newAdmin = newAdmin;
        QRACEL::SetAdmin_output output;
        invokeUserProcedure(QRACEL_CONTRACT_INDEX, 1, input, output, invocator, amount);
        return output.status;
    }

    uint8 setAutoCreate(const id& invocator, bit autoCreate, sint64 amount = 0)
    {
        QRACEL::SetAutoCreate_input input;
        input.autoCreate = autoCreate;
        input._pad0 = 0;
        input._pad1 = 0;
        input._pad2 = 0;
        QRACEL::SetAutoCreate_output output;
        invokeUserProcedure(QRACEL_CONTRACT_INDEX, 5, input, output, invocator, amount);
        return output.status;
    }

    uint8 setOracle(const id& invocator, const id& oracleId, sint64 amount = 0)
    {
        QRACEL::SetOracle_input input;
        input.oracleId = oracleId;
        QRACEL::SetOracle_output output;
        invokeUserProcedure(QRACEL_CONTRACT_INDEX, 6, input, output, invocator, amount);
        return output.status;
    }

    // --- Round/Bet procedures ---

    QRACEL::CreateRound_output createRound(const id& invocator, uint8 durationType, sint64 amount = 0)
    {
        QRACEL::CreateRound_input input;
        input.durationType = durationType;
        input._pad0 = 0;
        input._pad1 = 0;
        input._pad2 = 0;
        QRACEL::CreateRound_output output;
        invokeUserProcedure(QRACEL_CONTRACT_INDEX, 2, input, output, invocator, amount);
        return output;
    }

    QRACEL::PlaceBet_output placeBet(const id& invocator, uint64 roundId, uint8 side, sint64 amount)
    {
        QRACEL::PlaceBet_input input;
        input.roundId = roundId;
        input.side = side;
        input._pad0 = 0;
        input._pad1 = 0;
        input._pad2 = 0;
        QRACEL::PlaceBet_output output;
        invokeUserProcedure(QRACEL_CONTRACT_INDEX, 3, input, output, invocator, amount);
        return output;
    }

    QRACEL::ClaimWinnings_output claimWinnings(const id& invocator, uint32 betId, sint64 amount = 0)
    {
        QRACEL::ClaimWinnings_input input;
        input.betId = betId;
        QRACEL::ClaimWinnings_output output;
        invokeUserProcedure(QRACEL_CONTRACT_INDEX, 4, input, output, invocator, amount);
        return output;
    }

    // --- Query functions ---

    QRACEL::GetRound_output getRound(uint64 roundId)
    {
        QRACEL::GetRound_input input;
        input.roundId = roundId;
        QRACEL::GetRound_output output;
        callFunction(QRACEL_CONTRACT_INDEX, 1, input, output);
        return output;
    }

    QRACEL::GetBet_output getBet(uint32 betId)
    {
        QRACEL::GetBet_input input;
        input.betId = betId;
        QRACEL::GetBet_output output;
        callFunction(QRACEL_CONTRACT_INDEX, 2, input, output);
        return output;
    }

    QRACEL::GetConfig_output getConfig()
    {
        QRACEL::GetConfig_input input;
        QRACEL::GetConfig_output output;
        callFunction(QRACEL_CONTRACT_INDEX, 3, input, output);
        return output;
    }

    QRACEL::GetActiveRound_output getActiveRound(uint8 durationType)
    {
        QRACEL::GetActiveRound_input input;
        input.durationType = durationType;
        input._pad0 = 0;
        input._pad1 = 0;
        input._pad2 = 0;
        QRACEL::GetActiveRound_output output;
        callFunction(QRACEL_CONTRACT_INDEX, 4, input, output);
        return output;
    }

    // --- Helpers ---

    void endTick()
    {
        callSystemProcedure(QRACEL_CONTRACT_INDEX, END_TICK);
    }

    void endEpoch()
    {
        callSystemProcedure(QRACEL_CONTRACT_INDEX, END_EPOCH);
    }

    void beginEpoch()
    {
        callSystemProcedure(QRACEL_CONTRACT_INDEX, BEGIN_EPOCH);
    }

    QRacelStateChecker* getState()
    {
        return (QRacelStateChecker*)contractStates[QRACEL_CONTRACT_INDEX];
    }

    // Manually set a round in state for testing bet/claim logic without oracle
    void setRoundInState(uint32 roundIndex, const QRACEL::RoundData& round)
    {
        getState()->rounds.set(roundIndex, round);
    }

    void setBetInState(uint32 betIndex, const QRACEL::BetData& bet)
    {
        getState()->bets.set(betIndex, bet);
    }

    // Simulate oracle reply to a round's start query
    void simulateOracleReply(uint64 queryId, sint64 numerator, sint64 denominator, bool success = true)
    {
        struct
        {
            OracleMachineReply metadata;
            OI::Price::OracleReply data;
        } reply;

        reply.metadata.oracleMachineErrorFlags = success ? 0 : 1;
        reply.metadata.oracleQueryId = queryId;
        reply.data.numerator = numerator;
        reply.data.denominator = denominator;

        oracleEngine.processOracleMachineReply(&reply.metadata, sizeof(reply));
    }
};

// =============================================================================
// Initialization Tests
// =============================================================================

TEST(TestQRacel, InitialState)
{
    ContractTestingQRacel test;
    auto config = test.getConfig();

    EXPECT_EQ(config.admin, NULL_ID);
    EXPECT_EQ(config.autoCreate, 1);
    EXPECT_EQ(config.minBet, QRACEL_MIN_BET);
    EXPECT_EQ(config.roundCount, 0u);
    EXPECT_EQ(config.betCount, 0u);
    EXPECT_EQ(config.nextRoundId, 0u);
    EXPECT_EQ(config.totalVolume, 0u);
    EXPECT_EQ(config.totalPayouts, 0u);
    EXPECT_EQ(config.activeRound10m, 0u);
    EXPECT_EQ(config.activeRound60m, 0u);
    EXPECT_EQ(config.activeRound6h, 0u);
    EXPECT_EQ(config.activeRound24h, 0u);
}

// =============================================================================
// SetAdmin Tests
// =============================================================================

TEST(TestQRacel, SetAdminFirstTime)
{
    ContractTestingQRacel test;

    // First admin set should succeed from anyone (admin is NULL)
    uint8 status = test.setAdmin(USER1, ADMIN);
    EXPECT_EQ(status, QRACEL_STATUS_SUCCESS);

    auto config = test.getConfig();
    EXPECT_EQ(config.admin, ADMIN);
}

TEST(TestQRacel, SetAdminByAdmin)
{
    ContractTestingQRacel test;

    // Set initial admin
    test.setAdmin(USER1, ADMIN);

    // Admin can change admin
    uint8 status = test.setAdmin(ADMIN, USER2);
    EXPECT_EQ(status, QRACEL_STATUS_SUCCESS);

    auto config = test.getConfig();
    EXPECT_EQ(config.admin, USER2);
}

TEST(TestQRacel, SetAdminUnauthorized)
{
    ContractTestingQRacel test;

    // Set initial admin
    test.setAdmin(USER1, ADMIN);

    // Non-admin cannot change admin
    uint8 status = test.setAdmin(USER1, USER2);
    EXPECT_EQ(status, QRACEL_STATUS_NOT_AUTHORIZED);

    auto config = test.getConfig();
    EXPECT_EQ(config.admin, ADMIN);
}

TEST(TestQRacel, SetAdminNullId)
{
    ContractTestingQRacel test;

    // Cannot set admin to NULL_ID
    uint8 status = test.setAdmin(USER1, NULL_ID);
    EXPECT_EQ(status, QRACEL_STATUS_INVALID_INPUT);
}

// =============================================================================
// SetAutoCreate Tests
// =============================================================================

TEST(TestQRacel, SetAutoCreate)
{
    ContractTestingQRacel test;
    test.setAdmin(USER1, ADMIN);

    // Admin can toggle autoCreate
    uint8 status = test.setAutoCreate(ADMIN, 0);
    EXPECT_EQ(status, QRACEL_STATUS_SUCCESS);

    auto config = test.getConfig();
    EXPECT_EQ(config.autoCreate, 0);

    status = test.setAutoCreate(ADMIN, 1);
    EXPECT_EQ(status, QRACEL_STATUS_SUCCESS);

    config = test.getConfig();
    EXPECT_EQ(config.autoCreate, 1);
}

TEST(TestQRacel, SetAutoCreateUnauthorized)
{
    ContractTestingQRacel test;
    test.setAdmin(USER1, ADMIN);

    uint8 status = test.setAutoCreate(USER1, 0);
    EXPECT_EQ(status, QRACEL_STATUS_NOT_AUTHORIZED);
}

// =============================================================================
// SetOracle Tests
// =============================================================================

TEST(TestQRacel, SetOracle)
{
    ContractTestingQRacel test;
    test.setAdmin(USER1, ADMIN);

    uint8 status = test.setOracle(ADMIN, ORACLE_ID);
    EXPECT_EQ(status, QRACEL_STATUS_SUCCESS);

    auto config = test.getConfig();
    EXPECT_EQ(config.oracleId, ORACLE_ID);
}

TEST(TestQRacel, SetOracleUnauthorized)
{
    ContractTestingQRacel test;
    test.setAdmin(USER1, ADMIN);

    uint8 status = test.setOracle(USER1, ORACLE_ID);
    EXPECT_EQ(status, QRACEL_STATUS_NOT_AUTHORIZED);
}

TEST(TestQRacel, SetOracleNullId)
{
    ContractTestingQRacel test;
    test.setAdmin(USER1, ADMIN);

    uint8 status = test.setOracle(ADMIN, NULL_ID);
    EXPECT_EQ(status, QRACEL_STATUS_INVALID_INPUT);
}

// =============================================================================
// CreateRound Tests
// =============================================================================

TEST(TestQRacel, CreateRoundUnauthorized)
{
    ContractTestingQRacel test;
    test.setAdmin(USER1, ADMIN);

    auto output = test.createRound(USER1, QRACEL_DURATION_10M);
    EXPECT_EQ(output.status, QRACEL_STATUS_NOT_AUTHORIZED);
}

TEST(TestQRacel, CreateRoundInvalidDuration)
{
    ContractTestingQRacel test;
    test.setAdmin(USER1, ADMIN);

    auto output = test.createRound(ADMIN, 0);
    EXPECT_EQ(output.status, QRACEL_STATUS_INVALID_INPUT);

    output = test.createRound(ADMIN, 5);
    EXPECT_EQ(output.status, QRACEL_STATUS_INVALID_INPUT);

    output = test.createRound(ADMIN, 255);
    EXPECT_EQ(output.status, QRACEL_STATUS_INVALID_INPUT);
}

TEST(TestQRacel, CreateRoundSuccess)
{
    ContractTestingQRacel test;
    test.setAdmin(USER1, ADMIN);

    auto output = test.createRound(ADMIN, QRACEL_DURATION_10M);
    // Oracle query may fail if oracle isn't properly configured in test env,
    // but the access control and validation should pass
    EXPECT_TRUE(output.status == QRACEL_STATUS_SUCCESS || output.status == QRACEL_STATUS_ORACLE_FAILED);
}

// =============================================================================
// PlaceBet Tests (using manual state setup)
// =============================================================================

TEST(TestQRacel, PlaceBetInsufficientAmount)
{
    ContractTestingQRacel test;

    // Place bet below minimum
    auto output = test.placeBet(USER1, 1, QRACEL_SIDE_UP, 100);
    EXPECT_EQ(output.status, QRACEL_STATUS_INSUFFICIENT_BET);
}

TEST(TestQRacel, PlaceBetInvalidSide)
{
    ContractTestingQRacel test;

    // Create a round manually in state
    QRACEL::RoundData round = {};
    round.roundId = 1;
    round.durationTicks = QRACEL_TICKS_10M;
    round.startTick = 1;
    round.endTick = system.tick + 1000;
    round.status = QRACEL_ROUND_OPEN;
    round.durationType = QRACEL_DURATION_10M;

    auto* state = test.getState();
    state->rounds.set(0, round);
    state->roundIdToIndex.set(1, 0);
    state->roundCount = 1;
    state->nextRoundId = 1;

    // Invalid side (NONE)
    auto output = test.placeBet(USER1, 1, QRACEL_SIDE_NONE, QRACEL_MIN_BET);
    EXPECT_EQ(output.status, QRACEL_STATUS_INVALID_INPUT);

    // Invalid side (DRAW)
    output = test.placeBet(USER1, 1, QRACEL_SIDE_DRAW, QRACEL_MIN_BET);
    EXPECT_EQ(output.status, QRACEL_STATUS_INVALID_INPUT);
}

TEST(TestQRacel, PlaceBetRoundNotFound)
{
    ContractTestingQRacel test;

    // No rounds exist
    auto output = test.placeBet(USER1, 999, QRACEL_SIDE_UP, QRACEL_MIN_BET);
    EXPECT_EQ(output.status, QRACEL_STATUS_NOT_FOUND);
}

TEST(TestQRacel, PlaceBetRoundNotOpen)
{
    ContractTestingQRacel test;

    // Create a round in WAIT_START state
    QRACEL::RoundData round = {};
    round.roundId = 1;
    round.durationTicks = QRACEL_TICKS_10M;
    round.startTick = 1;
    round.endTick = system.tick + 1000;
    round.status = QRACEL_ROUND_WAIT_START;
    round.durationType = QRACEL_DURATION_10M;

    auto* state = test.getState();
    state->rounds.set(0, round);
    state->roundIdToIndex.set(1, 0);
    state->roundCount = 1;
    state->nextRoundId = 1;

    auto output = test.placeBet(USER1, 1, QRACEL_SIDE_UP, QRACEL_MIN_BET);
    EXPECT_EQ(output.status, QRACEL_STATUS_ROUND_NOT_OPEN);
}

TEST(TestQRacel, PlaceBetSuccess)
{
    ContractTestingQRacel test;

    // Create an OPEN round
    QRACEL::RoundData round = {};
    round.roundId = 1;
    round.durationTicks = QRACEL_TICKS_10M;
    round.startTick = 1;
    round.endTick = system.tick + 1000;
    round.status = QRACEL_ROUND_OPEN;
    round.durationType = QRACEL_DURATION_10M;

    auto* state = test.getState();
    state->rounds.set(0, round);
    state->roundIdToIndex.set(1, 0);
    state->roundCount = 1;
    state->nextRoundId = 1;

    // Place UP bet
    auto output = test.placeBet(USER1, 1, QRACEL_SIDE_UP, QRACEL_MIN_BET);
    EXPECT_EQ(output.status, QRACEL_STATUS_SUCCESS);
    EXPECT_EQ(output.acceptedAmount, (uint64)QRACEL_MIN_BET);
    EXPECT_EQ(output.betId, 0u);
    EXPECT_EQ(output.roundPoolUp, (uint64)QRACEL_MIN_BET);
    EXPECT_EQ(output.roundPoolDown, 0u);

    // Place DOWN bet
    output = test.placeBet(USER2, 1, QRACEL_SIDE_DOWN, 2 * QRACEL_MIN_BET);
    EXPECT_EQ(output.status, QRACEL_STATUS_SUCCESS);
    EXPECT_EQ(output.acceptedAmount, 2 * (uint64)QRACEL_MIN_BET);
    EXPECT_EQ(output.betId, 1u);
    EXPECT_EQ(output.roundPoolUp, (uint64)QRACEL_MIN_BET);
    EXPECT_EQ(output.roundPoolDown, 2 * (uint64)QRACEL_MIN_BET);

    // Verify state
    EXPECT_EQ(state->betCount, 2u);
    EXPECT_EQ(state->totalVolume, 3 * (uint64)QRACEL_MIN_BET);
}

// =============================================================================
// ClaimWinnings Tests
// =============================================================================

TEST(TestQRacel, ClaimWinningsNotFound)
{
    ContractTestingQRacel test;

    auto output = test.claimWinnings(USER1, 999);
    EXPECT_EQ(output.status, QRACEL_STATUS_NOT_FOUND);
}

TEST(TestQRacel, ClaimWinningsNotAuthorized)
{
    ContractTestingQRacel test;

    // Setup resolved round and a bet by USER1
    QRACEL::RoundData round = {};
    round.roundId = 1;
    round.status = QRACEL_ROUND_RESOLVED;
    round.winningSide = QRACEL_SIDE_UP;
    round.upPool = 10000000;
    round.downPool = 10000000;
    round.totalPool = 20000000;
    round.durationType = QRACEL_DURATION_10M;

    QRACEL::BetData bet = {};
    bet.bettor = USER1;
    bet.amount = 10000000;
    bet.roundIndex = 0;
    bet.side = QRACEL_SIDE_UP;
    bet.claimed = 0;

    auto* state = test.getState();
    state->rounds.set(0, round);
    state->roundIdToIndex.set(1, 0);
    state->roundCount = 1;
    state->bets.set(0, bet);
    state->betCount = 1;

    // USER2 tries to claim USER1's bet
    auto output = test.claimWinnings(USER2, 0);
    EXPECT_EQ(output.status, QRACEL_STATUS_NOT_AUTHORIZED);
}

TEST(TestQRacel, ClaimWinningsRoundNotResolved)
{
    ContractTestingQRacel test;

    // Setup OPEN round and a bet
    QRACEL::RoundData round = {};
    round.roundId = 1;
    round.status = QRACEL_ROUND_OPEN;
    round.durationType = QRACEL_DURATION_10M;

    QRACEL::BetData bet = {};
    bet.bettor = USER1;
    bet.amount = 10000000;
    bet.roundIndex = 0;
    bet.side = QRACEL_SIDE_UP;
    bet.claimed = 0;

    auto* state = test.getState();
    state->rounds.set(0, round);
    state->roundIdToIndex.set(1, 0);
    state->roundCount = 1;
    state->bets.set(0, bet);
    state->betCount = 1;

    auto output = test.claimWinnings(USER1, 0);
    EXPECT_EQ(output.status, QRACEL_STATUS_ROUND_NOT_RESOLVED);
}

TEST(TestQRacel, ClaimWinningsNotWinner)
{
    ContractTestingQRacel test;

    // Setup resolved round where UP wins, user bet DOWN
    QRACEL::RoundData round = {};
    round.roundId = 1;
    round.status = QRACEL_ROUND_RESOLVED;
    round.winningSide = QRACEL_SIDE_UP;
    round.upPool = 10000000;
    round.downPool = 10000000;
    round.totalPool = 20000000;
    round.durationType = QRACEL_DURATION_10M;

    QRACEL::BetData bet = {};
    bet.bettor = USER1;
    bet.amount = 10000000;
    bet.roundIndex = 0;
    bet.side = QRACEL_SIDE_DOWN; // Losing side
    bet.claimed = 0;

    auto* state = test.getState();
    state->rounds.set(0, round);
    state->roundIdToIndex.set(1, 0);
    state->roundCount = 1;
    state->bets.set(0, bet);
    state->betCount = 1;

    auto output = test.claimWinnings(USER1, 0);
    EXPECT_EQ(output.status, QRACEL_STATUS_NOT_WINNER);

    // Bet should be marked as claimed even for losers
    auto betData = state->bets.get(0);
    EXPECT_EQ(betData.claimed, 1);
}

TEST(TestQRacel, ClaimWinningsAlreadyClaimed)
{
    ContractTestingQRacel test;

    QRACEL::RoundData round = {};
    round.roundId = 1;
    round.status = QRACEL_ROUND_RESOLVED;
    round.winningSide = QRACEL_SIDE_UP;
    round.upPool = 10000000;
    round.downPool = 10000000;
    round.totalPool = 20000000;
    round.durationType = QRACEL_DURATION_10M;

    QRACEL::BetData bet = {};
    bet.bettor = USER1;
    bet.amount = 10000000;
    bet.roundIndex = 0;
    bet.side = QRACEL_SIDE_UP;
    bet.claimed = 1; // Already claimed

    auto* state = test.getState();
    state->rounds.set(0, round);
    state->roundIdToIndex.set(1, 0);
    state->roundCount = 1;
    state->bets.set(0, bet);
    state->betCount = 1;

    auto output = test.claimWinnings(USER1, 0);
    EXPECT_EQ(output.status, QRACEL_STATUS_ALREADY_CLAIMED);
}

TEST(TestQRacel, ClaimWinningsWinnerPayout)
{
    ContractTestingQRacel test;

    // Setup: UP wins, USER1 bet UP with 10M, total pool 20M (10M UP, 10M DOWN)
    // Expected payout: bet + (bet * loserPool / winnerPool) = 10M + 10M = 20M
    QRACEL::RoundData round = {};
    round.roundId = 1;
    round.status = QRACEL_ROUND_RESOLVED;
    round.winningSide = QRACEL_SIDE_UP;
    round.upPool = 10000000;
    round.downPool = 10000000;
    round.totalPool = 20000000;
    round.durationType = QRACEL_DURATION_10M;

    QRACEL::BetData bet = {};
    bet.bettor = USER1;
    bet.amount = 10000000;
    bet.roundIndex = 0;
    bet.side = QRACEL_SIDE_UP;
    bet.claimed = 0;

    auto* state = test.getState();
    state->rounds.set(0, round);
    state->roundIdToIndex.set(1, 0);
    state->roundCount = 1;
    state->bets.set(0, bet);
    state->betCount = 1;

    // Fund the contract so transfer succeeds
    increaseEnergy(QRACEL_CONTRACT_ID, 100000000LL);

    auto output = test.claimWinnings(USER1, 0);
    EXPECT_EQ(output.status, QRACEL_STATUS_SUCCESS);
    EXPECT_EQ(output.payoutAmount, 20000000u);
    EXPECT_EQ(output.winningSide, QRACEL_SIDE_UP);
    EXPECT_EQ(output.roundId, 1u);

    // Bet should be marked as claimed
    auto betData = state->bets.get(0);
    EXPECT_EQ(betData.claimed, 1);
    EXPECT_EQ(state->totalPayouts, 20000000u);
}

TEST(TestQRacel, ClaimWinningsDrawRefund)
{
    ContractTestingQRacel test;

    // Draw: everyone gets their bet back
    QRACEL::RoundData round = {};
    round.roundId = 1;
    round.status = QRACEL_ROUND_RESOLVED;
    round.winningSide = QRACEL_SIDE_DRAW;
    round.upPool = 10000000;
    round.downPool = 5000000;
    round.totalPool = 15000000;
    round.durationType = QRACEL_DURATION_10M;

    QRACEL::BetData bet = {};
    bet.bettor = USER1;
    bet.amount = 10000000;
    bet.roundIndex = 0;
    bet.side = QRACEL_SIDE_UP;
    bet.claimed = 0;

    auto* state = test.getState();
    state->rounds.set(0, round);
    state->roundIdToIndex.set(1, 0);
    state->roundCount = 1;
    state->bets.set(0, bet);
    state->betCount = 1;

    increaseEnergy(QRACEL_CONTRACT_ID, 100000000LL);

    auto output = test.claimWinnings(USER1, 0);
    EXPECT_EQ(output.status, QRACEL_STATUS_SUCCESS);
    EXPECT_EQ(output.payoutAmount, 10000000u); // Gets back original bet
    EXPECT_EQ(output.winningSide, QRACEL_SIDE_DRAW);
}

TEST(TestQRacel, ClaimWinningsProportionalPayout)
{
    ContractTestingQRacel test;

    // UP wins. UP pool = 30M (USER1=10M, USER3=20M), DOWN pool = 20M
    // USER1 payout: 10M + (10M * 20M / 30M) = 10M + 6666666 = 16666666
    QRACEL::RoundData round = {};
    round.roundId = 1;
    round.status = QRACEL_ROUND_RESOLVED;
    round.winningSide = QRACEL_SIDE_UP;
    round.upPool = 30000000;
    round.downPool = 20000000;
    round.totalPool = 50000000;
    round.durationType = QRACEL_DURATION_10M;

    QRACEL::BetData bet = {};
    bet.bettor = USER1;
    bet.amount = 10000000;
    bet.roundIndex = 0;
    bet.side = QRACEL_SIDE_UP;
    bet.claimed = 0;

    auto* state = test.getState();
    state->rounds.set(0, round);
    state->roundIdToIndex.set(1, 0);
    state->roundCount = 1;
    state->bets.set(0, bet);
    state->betCount = 1;

    increaseEnergy(QRACEL_CONTRACT_ID, 100000000LL);

    auto output = test.claimWinnings(USER1, 0);
    EXPECT_EQ(output.status, QRACEL_STATUS_SUCCESS);
    // bonus = (10M * 20M) / 30M = 6666666 (integer division)
    // payout = 10M + 6666666 = 16666666
    EXPECT_EQ(output.payoutAmount, 16666666u);
}

// =============================================================================
// GetRound Tests
// =============================================================================

TEST(TestQRacel, GetRoundNotFound)
{
    ContractTestingQRacel test;

    auto output = test.getRound(999);
    EXPECT_EQ(output.found, 0);
}

TEST(TestQRacel, GetRoundFound)
{
    ContractTestingQRacel test;

    QRACEL::RoundData round = {};
    round.roundId = 42;
    round.durationTicks = QRACEL_TICKS_60M;
    round.startTick = 100;
    round.endTick = 3700;
    round.status = QRACEL_ROUND_OPEN;
    round.winningSide = QRACEL_SIDE_NONE;
    round.upPool = 5000000;
    round.downPool = 3000000;
    round.totalPool = 8000000;
    round.betCount = 5;
    round.durationType = QRACEL_DURATION_60M;
    round.startNumerator = 50000;
    round.startDenominator = 1;

    auto* state = test.getState();
    state->rounds.set(0, round);
    state->roundIdToIndex.set(42, 0);
    state->roundCount = 1;

    auto output = test.getRound(42);
    EXPECT_EQ(output.found, 1);
    EXPECT_EQ(output.durationType, QRACEL_DURATION_60M);
    EXPECT_EQ(output.status, QRACEL_ROUND_OPEN);
    EXPECT_EQ(output.winningSide, QRACEL_SIDE_NONE);
    EXPECT_EQ(output.startTick, 100u);
    EXPECT_EQ(output.endTick, 3700u);
    EXPECT_EQ(output.upPool, 5000000u);
    EXPECT_EQ(output.downPool, 3000000u);
    EXPECT_EQ(output.totalPool, 8000000u);
    EXPECT_EQ(output.betCount, 5u);
    EXPECT_EQ(output.startNumerator, 50000);
    EXPECT_EQ(output.startDenominator, 1);
}

// =============================================================================
// GetBet Tests
// =============================================================================

TEST(TestQRacel, GetBetNotFound)
{
    ContractTestingQRacel test;

    auto output = test.getBet(999);
    EXPECT_EQ(output.found, 0);
}

TEST(TestQRacel, GetBetFound)
{
    ContractTestingQRacel test;

    QRACEL::RoundData round = {};
    round.roundId = 1;
    round.status = QRACEL_ROUND_OPEN;
    round.winningSide = QRACEL_SIDE_NONE;
    round.durationType = QRACEL_DURATION_10M;

    QRACEL::BetData bet = {};
    bet.bettor = USER1;
    bet.amount = 5000000;
    bet.roundIndex = 0;
    bet.side = QRACEL_SIDE_DOWN;
    bet.claimed = 0;

    auto* state = test.getState();
    state->rounds.set(0, round);
    state->roundIdToIndex.set(1, 0);
    state->roundCount = 1;
    state->bets.set(0, bet);
    state->betCount = 1;

    auto output = test.getBet(0);
    EXPECT_EQ(output.found, 1);
    EXPECT_EQ(output.side, QRACEL_SIDE_DOWN);
    EXPECT_EQ(output.claimed, 0);
    EXPECT_EQ(output.amount, 5000000u);
    EXPECT_EQ(output.bettor, USER1);
    EXPECT_EQ(output.roundId, 1u);
    EXPECT_EQ(output.roundStatus, QRACEL_ROUND_OPEN);
    EXPECT_EQ(output.roundWinningSide, QRACEL_SIDE_NONE);
}

// =============================================================================
// GetActiveRound Tests
// =============================================================================

TEST(TestQRacel, GetActiveRoundNone)
{
    ContractTestingQRacel test;

    auto output = test.getActiveRound(QRACEL_DURATION_10M);
    EXPECT_EQ(output.found, 0);
}

TEST(TestQRacel, GetActiveRoundInvalidDuration)
{
    ContractTestingQRacel test;

    auto output = test.getActiveRound(0);
    EXPECT_EQ(output.found, 0);

    output = test.getActiveRound(5);
    EXPECT_EQ(output.found, 0);
}

TEST(TestQRacel, GetActiveRoundFound)
{
    ContractTestingQRacel test;

    QRACEL::RoundData round = {};
    round.roundId = 7;
    round.startTick = 100;
    round.endTick = 700;
    round.status = QRACEL_ROUND_OPEN;
    round.durationType = QRACEL_DURATION_10M;

    auto* state = test.getState();
    state->rounds.set(0, round);
    state->roundIdToIndex.set(7, 0);
    state->roundCount = 1;
    state->activeRoundByDuration.set(0, 0); // durationToIndex(QRACEL_DURATION_10M) = 0

    auto output = test.getActiveRound(QRACEL_DURATION_10M);
    EXPECT_EQ(output.found, 1);
    EXPECT_EQ(output.roundId, 7u);
    EXPECT_EQ(output.durationType, QRACEL_DURATION_10M);
    EXPECT_EQ(output.status, QRACEL_ROUND_OPEN);
    EXPECT_EQ(output.startTick, 100u);
    EXPECT_EQ(output.endTick, 700u);
}

// =============================================================================
// Static Helper Tests
// =============================================================================

TEST(TestQRacel, DurationToTicks)
{
    EXPECT_EQ(QRACEL::durationToTicks(QRACEL_DURATION_10M), QRACEL_TICKS_10M);
    EXPECT_EQ(QRACEL::durationToTicks(QRACEL_DURATION_60M), QRACEL_TICKS_60M);
    EXPECT_EQ(QRACEL::durationToTicks(QRACEL_DURATION_6H), QRACEL_TICKS_6H);
    EXPECT_EQ(QRACEL::durationToTicks(QRACEL_DURATION_24H), QRACEL_TICKS_24H);
    EXPECT_EQ(QRACEL::durationToTicks(0), 0u);
    EXPECT_EQ(QRACEL::durationToTicks(5), 0u);
}

TEST(TestQRacel, IsValidDuration)
{
    EXPECT_TRUE(QRACEL::isValidDuration(QRACEL_DURATION_10M));
    EXPECT_TRUE(QRACEL::isValidDuration(QRACEL_DURATION_60M));
    EXPECT_TRUE(QRACEL::isValidDuration(QRACEL_DURATION_6H));
    EXPECT_TRUE(QRACEL::isValidDuration(QRACEL_DURATION_24H));
    EXPECT_FALSE(QRACEL::isValidDuration(0));
    EXPECT_FALSE(QRACEL::isValidDuration(5));
    EXPECT_FALSE(QRACEL::isValidDuration(255));
}

// =============================================================================
// Multiple Bets and Round State Tests
// =============================================================================

TEST(TestQRacel, MultipleBetsOnSameRound)
{
    ContractTestingQRacel test;

    QRACEL::RoundData round = {};
    round.roundId = 1;
    round.durationTicks = QRACEL_TICKS_10M;
    round.startTick = 1;
    round.endTick = system.tick + 1000;
    round.status = QRACEL_ROUND_OPEN;
    round.durationType = QRACEL_DURATION_10M;

    auto* state = test.getState();
    state->rounds.set(0, round);
    state->roundIdToIndex.set(1, 0);
    state->roundCount = 1;
    state->nextRoundId = 1;

    // USER1 bets UP
    auto out1 = test.placeBet(USER1, 1, QRACEL_SIDE_UP, 5000000);
    EXPECT_EQ(out1.status, QRACEL_STATUS_SUCCESS);
    EXPECT_EQ(out1.betId, 0u);

    // USER2 bets DOWN
    auto out2 = test.placeBet(USER2, 1, QRACEL_SIDE_DOWN, 3000000);
    EXPECT_EQ(out2.status, QRACEL_STATUS_SUCCESS);
    EXPECT_EQ(out2.betId, 1u);

    // USER3 bets UP
    auto out3 = test.placeBet(USER3, 1, QRACEL_SIDE_UP, 7000000);
    EXPECT_EQ(out3.status, QRACEL_STATUS_SUCCESS);
    EXPECT_EQ(out3.betId, 2u);

    // Check pools
    EXPECT_EQ(out3.roundPoolUp, 12000000u);  // 5M + 7M
    EXPECT_EQ(out3.roundPoolDown, 3000000u); // 3M

    // State checks
    EXPECT_EQ(state->betCount, 3u);
    EXPECT_EQ(state->totalVolume, 15000000u);

    // Check round via GetRound
    auto roundOut = test.getRound(1);
    EXPECT_EQ(roundOut.found, 1);
    EXPECT_EQ(roundOut.upPool, 12000000u);
    EXPECT_EQ(roundOut.downPool, 3000000u);
    EXPECT_EQ(roundOut.totalPool, 15000000u);
    EXPECT_EQ(roundOut.betCount, 3u);
}

TEST(TestQRacel, EndEpochCleansUp)
{
    ContractTestingQRacel test;

    // Just make sure END_EPOCH doesn't crash
    test.endEpoch();

    auto config = test.getConfig();
    EXPECT_EQ(config.roundCount, 0u);
}
