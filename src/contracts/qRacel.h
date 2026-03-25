using namespace QPI;

constexpr uint64 QRACEL_MAX_ROUNDS = 16384;
constexpr uint64 QRACEL_MAX_BETS = 65536;
constexpr uint64 QRACEL_MIN_BET = 1000000;
constexpr uint64 QRACEL_MAX_TRANSFERABLE = 9223372036854775807ULL;

constexpr uint8 QRACEL_DURATION_10M = 1;
constexpr uint8 QRACEL_DURATION_60M = 2;
constexpr uint8 QRACEL_DURATION_6H = 3;
constexpr uint8 QRACEL_DURATION_24H = 4;
constexpr uint8 QRACEL_DURATION_COUNT = 4;

constexpr uint32 QRACEL_TICKS_10M = 600;
constexpr uint32 QRACEL_TICKS_60M = 3600;
constexpr uint32 QRACEL_TICKS_6H = 21600;
constexpr uint32 QRACEL_TICKS_24H = 86400;

constexpr uint8 QRACEL_SIDE_NONE = 0;
constexpr uint8 QRACEL_SIDE_UP = 1;
constexpr uint8 QRACEL_SIDE_DOWN = 2;
constexpr uint8 QRACEL_SIDE_DRAW = 3;

constexpr uint8 QRACEL_ROUND_WAIT_START = 1;
constexpr uint8 QRACEL_ROUND_OPEN = 2;
constexpr uint8 QRACEL_ROUND_WAIT_END = 3;
constexpr uint8 QRACEL_ROUND_RESOLVED = 4;

constexpr uint8 QRACEL_QUERY_PHASE_START = 1;
constexpr uint8 QRACEL_QUERY_PHASE_END = 2;

constexpr uint32 QRACEL_ORACLE_TIMEOUT_MS = 120000;
constexpr uint32 QRACEL_ORACLE_RETRY_TICKS = 30;
constexpr uint32 QRACEL_NO_ROUND = 0xFFFFFFFFU;

constexpr uint8 QRACEL_STATUS_SUCCESS = 1;
constexpr uint8 QRACEL_STATUS_NOT_AUTHORIZED = 2;
constexpr uint8 QRACEL_STATUS_INVALID_INPUT = 3;
constexpr uint8 QRACEL_STATUS_NOT_FOUND = 4;
constexpr uint8 QRACEL_STATUS_LIMIT_REACHED = 5;
constexpr uint8 QRACEL_STATUS_ROUND_NOT_OPEN = 6;
constexpr uint8 QRACEL_STATUS_INSUFFICIENT_BET = 7;
constexpr uint8 QRACEL_STATUS_ALREADY_CLAIMED = 8;
constexpr uint8 QRACEL_STATUS_NOT_WINNER = 9;
constexpr uint8 QRACEL_STATUS_TRANSFER_FAILED = 10;
constexpr uint8 QRACEL_STATUS_ORACLE_FAILED = 11;
constexpr uint8 QRACEL_STATUS_ROUND_NOT_RESOLVED = 12;
constexpr uint8 QRACEL_STATUS_ALREADY_ACTIVE = 13;

struct QRACEL2
{
};

struct QRACEL : public ContractBase
{
    struct RoundData
    {
        uint64 roundId;
        uint32 durationTicks;
        uint32 startTick;
        uint32 endTick;
        uint32 resolvedTick;
        uint32 betCount;
        uint64 upPool;
        uint64 downPool;
        uint64 totalPool;
        sint64 startNumerator;
        sint64 startDenominator;
        sint64 endNumerator;
        sint64 endDenominator;
        sint64 startQueryId;
        sint64 endQueryId;
        uint32 nextOracleRetryTick;
        uint8 durationType;
        uint8 status;
        uint8 winningSide;
        uint8 _pad0;
    };

    struct BetData
    {
        id bettor;
        uint64 amount;
        uint32 roundIndex;
        uint8 side;
        uint8 claimed;
        uint16 _pad0;
    };

    struct OracleQueryContext
    {
        uint32 roundIndex;
        uint8 phase;
        uint8 _pad0;
        uint16 _pad1;
    };

    struct StateData
    {
        id admin;
        id oracleId;
        uint8 autoCreate;
        uint8 _pad0;
        uint16 _pad1;
        uint32 _pad2;
        uint32 roundCount;
        uint32 betCount;
        uint64 nextRoundId;
        uint64 totalVolume;
        uint64 totalPayouts;
        sint64 dbgLastQueryId;
        uint32 dbgCreateRoundCalls;
        uint32 dbgOracleFails;
        uint8 dbgLastStatus;
        uint8 _dbgPad0;
        uint16 _dbgPad1;
        uint32 dbgActiveRaw;
        uint32 dbgEndTickAutoCreates;
        Array<RoundData, QRACEL_MAX_ROUNDS> rounds;
        Array<BetData, QRACEL_MAX_BETS> bets;
        Array<uint32, QRACEL_DURATION_COUNT> activeRoundByDuration;
        HashMap<uint64, uint32, QRACEL_MAX_ROUNDS> roundIdToIndex;
        HashMap<uint64, OracleQueryContext, 1024> oracleQueryContext;
    };

    static bool isValidDuration(uint8 durationType)
    {
        return durationType >= QRACEL_DURATION_10M && durationType <= QRACEL_DURATION_24H;
    }

    static uint32 durationToTicks(uint8 durationType)
    {
        if (durationType == QRACEL_DURATION_10M)
            return QRACEL_TICKS_10M;
        if (durationType == QRACEL_DURATION_60M)
            return QRACEL_TICKS_60M;
        if (durationType == QRACEL_DURATION_6H)
            return QRACEL_TICKS_6H;
        if (durationType == QRACEL_DURATION_24H)
            return QRACEL_TICKS_24H;
        return 0;
    }

    static uint32 durationToIndex(uint8 durationType)
    {
        return durationType - 1;
    }

    static void setupBtcUsdtQuery(const id& oracleId, const DateAndTime& timestamp, OI::Price::OracleQuery& query)
    {
        using namespace Ch;
        query.oracle = oracleId;
        query.timestamp = timestamp;
        query.currency1 = id(B, T, C, null, null);
        query.currency2 = id(U, S, D, T, null);
    }

    struct SetAdmin_input
    {
        id newAdmin;
    };
    struct SetAdmin_output
    {
        uint8 status;
    };

    struct SetAutoCreate_input
    {
        uint8 autoCreate;
        uint8 _pad0;
        uint16 _pad1;
        uint32 _pad2;
    };
    struct SetAutoCreate_output
    {
        uint8 status;
    };

    struct SetOracle_input
    {
        id oracleId;
    };
    struct SetOracle_output
    {
        uint8 status;
    };

    struct Fund_input
    {
    };
    struct Fund_output
    {
        uint8 status;
    };

    struct CreateRound_input
    {
        uint8 durationType;
        uint8 _pad0;
        uint16 _pad1;
        uint32 _pad2;
    };
    struct CreateRound_output
    {
        uint8 status;
        uint8 _pad0;
        uint16 _pad1;
        uint32 startTick;
        uint32 endTick;
        uint64 roundId;
        sint64 startQueryId;
    };
    struct CreateRound_locals
    {
        uint32 durationIndex;
        uint32 roundIndex;
        uint32 durationTicks;
        RoundData round;
        OI::Price::OracleQuery query;
        sint64 queryId;
        OracleQueryContext queryContext;
    };

    struct PlaceBet_input
    {
        uint64 roundId;
        uint8 side;
        uint8 _pad0;
        uint16 _pad1;
        uint32 _pad2;
    };
    struct PlaceBet_output
    {
        uint8 status;
        uint8 _pad0;
        uint16 _pad1;
        uint32 betId;
        uint64 acceptedAmount;
        uint64 roundPoolUp;
        uint64 roundPoolDown;
    };
    struct PlaceBet_locals
    {
        sint64 reward;
        uint32 roundIndex;
        RoundData round;
        BetData bet;
        uint64 amount;
    };

    struct ClaimWinnings_input
    {
        uint32 betId;
    };
    struct ClaimWinnings_output
    {
        uint8 status;
        uint8 winningSide;
        uint16 _pad0;
        uint32 _pad1;
        uint64 roundId;
        uint64 payoutAmount;
    };
    struct ClaimWinnings_locals
    {
        BetData bet;
        RoundData round;
        uint64 payout;
        uint64 winnerPool;
        uint64 loserPool;
        uint64 bonus;
        sint64 transferResult;
    };

    struct GetRound_input
    {
        uint64 roundId;
    };
    struct GetRound_output
    {
        uint8 found;
        uint8 durationType;
        uint8 status;
        uint8 winningSide;
        uint32 startTick;
        uint32 endTick;
        uint32 resolvedTick;
        uint32 betCount;
        uint64 upPool;
        uint64 downPool;
        uint64 totalPool;
        sint64 startNumerator;
        sint64 startDenominator;
        sint64 endNumerator;
        sint64 endDenominator;
        sint64 startQueryId;
        sint64 endQueryId;
    };
    struct GetRound_locals
    {
        uint32 roundIndex;
        RoundData round;
    };

    struct GetBet_input
    {
        uint32 betId;
    };
    struct GetBet_output
    {
        uint8 found;
        uint8 side;
        uint8 claimed;
        uint8 roundStatus;
        uint8 roundWinningSide;
        uint8 _pad0;
        uint16 _pad1;
        uint32 roundIndex;
        uint64 amount;
        uint64 roundId;
        id bettor;
    };
    struct GetBet_locals
    {
        BetData bet;
        RoundData round;
    };

    struct GetConfig_input
    {
    };
    struct GetConfig_output
    {
        id admin;
        id oracleId;
        uint8 autoCreate;
        uint8 _pad0;
        uint16 _pad1;
        uint32 _pad2;
        uint64 minBet;
        uint32 roundCount;
        uint32 betCount;
        uint64 nextRoundId;
        uint64 totalVolume;
        uint64 totalPayouts;
        uint64 activeRound10m;
        uint64 activeRound60m;
        uint64 activeRound6h;
        uint64 activeRound24h;
        sint64 dbgLastQueryId;
        uint32 dbgCreateRoundCalls;
        uint32 dbgOracleFails;
        uint8 dbgLastStatus;
        uint8 _dbgPad0;
        uint16 _dbgPad1;
        uint32 dbgActiveRaw;
        uint32 dbgEndTickAutoCreates;
    };
    struct GetConfig_locals
    {
        uint32 idx;
    };

    struct GetActiveRound_input
    {
        uint8 durationType;
        uint8 _pad0;
        uint16 _pad1;
        uint32 _pad2;
    };
    struct GetActiveRound_output
    {
        uint8 found;
        uint8 durationType;
        uint8 status;
        uint8 _pad0;
        uint32 startTick;
        uint32 endTick;
        uint64 roundId;
    };
    struct GetActiveRound_locals
    {
        uint32 durationIndex;
        uint32 roundIndex;
        RoundData round;
    };

    typedef OracleNotificationInput<OI::Price> NotifyPriceOracleReply_input;
    typedef NoData NotifyPriceOracleReply_output;
    struct NotifyPriceOracleReply_locals
    {
        OracleQueryContext queryContext;
        RoundData round;
        uint32 durationIndex;
        uint64 lhs;
        uint64 rhs;
    };

    struct INITIALIZE_locals
    {
        uint32 i;
    };

    struct END_TICK_locals
    {
        uint8 i;
        uint8 durationType;
        uint32 durationIndex;
        uint32 roundIndex;
        uint32 durationTicks;
        RoundData round;
        OI::Price::OracleQuery query;
        sint64 queryId;
        OracleQueryContext queryContext;
    };

    REGISTER_USER_FUNCTIONS_AND_PROCEDURES()
    {
        REGISTER_USER_PROCEDURE(SetAdmin, 1);
        REGISTER_USER_PROCEDURE(CreateRound, 2);
        REGISTER_USER_PROCEDURE(PlaceBet, 3);
        REGISTER_USER_PROCEDURE(ClaimWinnings, 4);
        REGISTER_USER_PROCEDURE(SetAutoCreate, 5);
        REGISTER_USER_PROCEDURE(SetOracle, 6);
        REGISTER_USER_PROCEDURE(Fund, 7);

        REGISTER_USER_FUNCTION(GetRound, 1);
        REGISTER_USER_FUNCTION(GetBet, 2);
        REGISTER_USER_FUNCTION(GetConfig, 3);
        REGISTER_USER_FUNCTION(GetActiveRound, 4);

        REGISTER_USER_PROCEDURE_NOTIFICATION(NotifyPriceOracleReply);
    }

    PUBLIC_PROCEDURE(SetAdmin)
    {
        output.status = QRACEL_STATUS_NOT_AUTHORIZED;
        if (input.newAdmin == NULL_ID)
        {
            output.status = QRACEL_STATUS_INVALID_INPUT;
            return;
        }

        if (state.get().admin == NULL_ID || qpi.invocator() == state.get().admin)
        {
            state.mut().admin = input.newAdmin;
            output.status = QRACEL_STATUS_SUCCESS;
        }
    }

    PUBLIC_PROCEDURE(SetAutoCreate)
    {
        output.status = QRACEL_STATUS_NOT_AUTHORIZED;
        if (qpi.invocator() != state.get().admin)
            return;

        state.mut().autoCreate = input.autoCreate;
        output.status = QRACEL_STATUS_SUCCESS;
    }

    PUBLIC_PROCEDURE(SetOracle)
    {
        output.status = QRACEL_STATUS_NOT_AUTHORIZED;
        if (qpi.invocator() != state.get().admin)
            return;

        if (input.oracleId == NULL_ID)
        {
            output.status = QRACEL_STATUS_INVALID_INPUT;
            return;
        }

        state.mut().oracleId = input.oracleId;
        output.status = QRACEL_STATUS_SUCCESS;
    }

    PUBLIC_PROCEDURE(Fund)
    {
        output.status = QRACEL_STATUS_SUCCESS;
    }

    PUBLIC_PROCEDURE_WITH_LOCALS(CreateRound)
    {
        output.status = QRACEL_STATUS_NOT_AUTHORIZED;
        output.roundId = 0;
        output.startTick = 0;
        output.endTick = 0;
        output.startQueryId = -1;

        state.mut().dbgCreateRoundCalls = state.get().dbgCreateRoundCalls + 1;

        if (qpi.invocator() != state.get().admin)
        {
            state.mut().dbgLastStatus = 1;
            return;
        }

        if (!isValidDuration(input.durationType))
        {
            state.mut().dbgLastStatus = 2;
            output.status = QRACEL_STATUS_INVALID_INPUT;
            return;
        }

        locals.durationIndex = durationToIndex(input.durationType);
        state.mut().dbgActiveRaw = state.get().activeRoundByDuration.get(locals.durationIndex);
        if (state.get().activeRoundByDuration.get(locals.durationIndex) != QRACEL_NO_ROUND)
        {
            state.mut().dbgLastStatus = 3;
            output.status = QRACEL_STATUS_ALREADY_ACTIVE;
            return;
        }

        if (state.get().roundCount >= QRACEL_MAX_ROUNDS)
        {
            state.mut().dbgLastStatus = 4;
            output.status = QRACEL_STATUS_LIMIT_REACHED;
            return;
        }

        locals.durationTicks = durationToTicks(input.durationType);
        if (locals.durationTicks == 0)
        {
            state.mut().dbgLastStatus = 5;
            output.status = QRACEL_STATUS_INVALID_INPUT;
            return;
        }

        locals.roundIndex = state.get().roundCount;
        locals.round.roundId = state.get().nextRoundId + 1;
        locals.round.durationTicks = locals.durationTicks;
        locals.round.startTick = qpi.tick();
        locals.round.endTick = qpi.tick() + locals.durationTicks;
        locals.round.resolvedTick = 0;
        locals.round.betCount = 0;
        locals.round.upPool = 0;
        locals.round.downPool = 0;
        locals.round.totalPool = 0;
        locals.round.startNumerator = 0;
        locals.round.startDenominator = 0;
        locals.round.endNumerator = 0;
        locals.round.endDenominator = 0;
        locals.round.startQueryId = 0;
        locals.round.endQueryId = 0;
        locals.round.nextOracleRetryTick = 0;
        locals.round.durationType = input.durationType;
        locals.round.status = QRACEL_ROUND_WAIT_START;
        locals.round.winningSide = QRACEL_SIDE_NONE;
        locals.round._pad0 = 0;

        setupBtcUsdtQuery(state.get().oracleId, qpi.now(), locals.query);
        locals.queryId = QUERY_ORACLE(OI::Price, locals.query, NotifyPriceOracleReply, QRACEL_ORACLE_TIMEOUT_MS);
        state.mut().dbgLastQueryId = locals.queryId;
        if (locals.queryId < 0)
        {
            state.mut().dbgOracleFails = state.get().dbgOracleFails + 1;
            state.mut().dbgLastStatus = 10;
            output.status = QRACEL_STATUS_ORACLE_FAILED;
            return;
        }

        locals.round.startQueryId = locals.queryId;
        state.mut().rounds.set(locals.roundIndex, locals.round);
        state.mut().roundIdToIndex.set(locals.round.roundId, locals.roundIndex);

        locals.queryContext.roundIndex = locals.roundIndex;
        locals.queryContext.phase = QRACEL_QUERY_PHASE_START;
        locals.queryContext._pad0 = 0;
        locals.queryContext._pad1 = 0;
        state.mut().oracleQueryContext.set((uint64)locals.queryId, locals.queryContext);

        state.mut().activeRoundByDuration.set(locals.durationIndex, locals.roundIndex);
        state.mut().roundCount = state.get().roundCount + 1;
        state.mut().nextRoundId = locals.round.roundId;

        output.roundId = locals.round.roundId;
        output.startTick = locals.round.startTick;
        output.endTick = locals.round.endTick;
        output.startQueryId = locals.queryId;
        output.status = QRACEL_STATUS_SUCCESS;
    }

    PUBLIC_PROCEDURE_WITH_LOCALS(PlaceBet)
    {
        output.status = QRACEL_STATUS_INVALID_INPUT;
        output.betId = 0;
        output.acceptedAmount = 0;
        output.roundPoolUp = 0;
        output.roundPoolDown = 0;

        locals.reward = qpi.invocationReward();
        if (locals.reward < (sint64)QRACEL_MIN_BET)
        {
            if (locals.reward > 0)
            {
                qpi.transfer(qpi.invocator(), locals.reward);
            }
            output.status = QRACEL_STATUS_INSUFFICIENT_BET;
            return;
        }

        if (input.side != QRACEL_SIDE_UP && input.side != QRACEL_SIDE_DOWN)
        {
            qpi.transfer(qpi.invocator(), locals.reward);
            output.status = QRACEL_STATUS_INVALID_INPUT;
            return;
        }

        if (state.get().betCount >= QRACEL_MAX_BETS)
        {
            qpi.transfer(qpi.invocator(), locals.reward);
            output.status = QRACEL_STATUS_LIMIT_REACHED;
            return;
        }

        if (!state.get().roundIdToIndex.get(input.roundId, locals.roundIndex))
        {
            qpi.transfer(qpi.invocator(), locals.reward);
            output.status = QRACEL_STATUS_NOT_FOUND;
            return;
        }

        if (locals.roundIndex >= state.get().roundCount)
        {
            qpi.transfer(qpi.invocator(), locals.reward);
            output.status = QRACEL_STATUS_NOT_FOUND;
            return;
        }

        locals.round = state.get().rounds.get(locals.roundIndex);
        if (locals.round.status != QRACEL_ROUND_OPEN || qpi.tick() >= locals.round.endTick)
        {
            qpi.transfer(qpi.invocator(), locals.reward);
            output.status = QRACEL_STATUS_ROUND_NOT_OPEN;
            return;
        }

        locals.amount = (uint64)locals.reward;
        locals.bet.bettor = qpi.invocator();
        locals.bet.amount = locals.amount;
        locals.bet.roundIndex = locals.roundIndex;
        locals.bet.side = input.side;
        locals.bet.claimed = 0;
        locals.bet._pad0 = 0;

        state.mut().bets.set(state.get().betCount, locals.bet);
        output.betId = state.get().betCount;
        state.mut().betCount = state.get().betCount + 1;

        if (input.side == QRACEL_SIDE_UP)
        {
            locals.round.upPool = sadd(locals.round.upPool, locals.amount);
        }
        else
        {
            locals.round.downPool = sadd(locals.round.downPool, locals.amount);
        }
        locals.round.totalPool = sadd(locals.round.totalPool, locals.amount);
        locals.round.betCount = locals.round.betCount + 1;

        state.mut().rounds.set(locals.roundIndex, locals.round);
        state.mut().totalVolume = sadd(state.get().totalVolume, locals.amount);

        output.acceptedAmount = locals.amount;
        output.roundPoolUp = locals.round.upPool;
        output.roundPoolDown = locals.round.downPool;
        output.status = QRACEL_STATUS_SUCCESS;
    }

    PUBLIC_PROCEDURE_WITH_LOCALS(ClaimWinnings)
    {
        output.status = QRACEL_STATUS_INVALID_INPUT;
        output.winningSide = QRACEL_SIDE_NONE;
        output.roundId = 0;
        output.payoutAmount = 0;

        if (input.betId >= state.get().betCount)
        {
            output.status = QRACEL_STATUS_NOT_FOUND;
            return;
        }

        locals.bet = state.get().bets.get(input.betId);
        if (locals.bet.bettor != qpi.invocator())
        {
            output.status = QRACEL_STATUS_NOT_AUTHORIZED;
            return;
        }

        if (locals.bet.claimed)
        {
            output.status = QRACEL_STATUS_ALREADY_CLAIMED;
            return;
        }

        if (locals.bet.roundIndex >= state.get().roundCount)
        {
            output.status = QRACEL_STATUS_NOT_FOUND;
            return;
        }

        locals.round = state.get().rounds.get(locals.bet.roundIndex);
        output.roundId = locals.round.roundId;
        output.winningSide = locals.round.winningSide;

        if (locals.round.status != QRACEL_ROUND_RESOLVED)
        {
            output.status = QRACEL_STATUS_ROUND_NOT_RESOLVED;
            return;
        }

        if (locals.round.winningSide == QRACEL_SIDE_DRAW)
        {
            locals.payout = locals.bet.amount;
        }
        else if (locals.bet.side != locals.round.winningSide)
        {
            locals.bet.claimed = 1;
            state.mut().bets.set(input.betId, locals.bet);
            output.status = QRACEL_STATUS_NOT_WINNER;
            return;
        }
        else
        {
            locals.winnerPool = (locals.round.winningSide == QRACEL_SIDE_UP) ? locals.round.upPool : locals.round.downPool;
            if (locals.winnerPool == 0)
            {
                locals.payout = locals.bet.amount;
            }
            else
            {
                locals.loserPool = locals.round.totalPool - locals.winnerPool;
                locals.bonus = div<uint64>(smul(locals.bet.amount, locals.loserPool), locals.winnerPool);
                locals.payout = sadd(locals.bet.amount, locals.bonus);
            }
        }

        if (locals.payout > QRACEL_MAX_TRANSFERABLE)
        {
            output.status = QRACEL_STATUS_TRANSFER_FAILED;
            return;
        }

        locals.transferResult = qpi.transfer(qpi.invocator(), (sint64)locals.payout);
        if (locals.transferResult < 0)
        {
            output.status = QRACEL_STATUS_TRANSFER_FAILED;
            return;
        }

        locals.bet.claimed = 1;
        state.mut().bets.set(input.betId, locals.bet);
        state.mut().totalPayouts = sadd(state.get().totalPayouts, locals.payout);

        output.payoutAmount = locals.payout;
        output.status = QRACEL_STATUS_SUCCESS;
    }

    PRIVATE_PROCEDURE_WITH_LOCALS(NotifyPriceOracleReply)
    {
        if (!state.get().oracleQueryContext.get((uint64)input.queryId, locals.queryContext))
            return;

        state.mut().oracleQueryContext.removeByKey((uint64)input.queryId);

        if (locals.queryContext.roundIndex >= state.get().roundCount)
            return;

        locals.round = state.get().rounds.get(locals.queryContext.roundIndex);

        if (locals.queryContext.phase == QRACEL_QUERY_PHASE_START)
        {
            if (locals.round.startQueryId != input.queryId)
                return;

            locals.round.startQueryId = 0;
            if (input.status == ORACLE_QUERY_STATUS_SUCCESS && OI::Price::replyIsValid(input.reply))
            {
                locals.round.startNumerator = input.reply.numerator;
                locals.round.startDenominator = input.reply.denominator;
                locals.round.status = QRACEL_ROUND_OPEN;
                locals.round.nextOracleRetryTick = 0;
            }
            else
            {
                locals.round.status = QRACEL_ROUND_WAIT_START;
                locals.round.nextOracleRetryTick = qpi.tick() + QRACEL_ORACLE_RETRY_TICKS;
            }

            state.mut().rounds.set(locals.queryContext.roundIndex, locals.round);
            return;
        }

        if (locals.queryContext.phase == QRACEL_QUERY_PHASE_END)
        {
            if (locals.round.endQueryId != input.queryId)
                return;

            locals.round.endQueryId = 0;
            if (input.status == ORACLE_QUERY_STATUS_SUCCESS && OI::Price::replyIsValid(input.reply))
            {
                locals.round.endNumerator = input.reply.numerator;
                locals.round.endDenominator = input.reply.denominator;

                locals.lhs = smul((uint64)locals.round.endNumerator, (uint64)locals.round.startDenominator);
                locals.rhs = smul((uint64)locals.round.startNumerator, (uint64)locals.round.endDenominator);
                if (locals.lhs > locals.rhs)
                {
                    locals.round.winningSide = QRACEL_SIDE_UP;
                }
                else if (locals.lhs < locals.rhs)
                {
                    locals.round.winningSide = QRACEL_SIDE_DOWN;
                }
                else
                {
                    locals.round.winningSide = QRACEL_SIDE_DRAW;
                }

                if (locals.round.upPool == 0 || locals.round.downPool == 0)
                {
                    locals.round.winningSide = QRACEL_SIDE_DRAW;
                }

                locals.round.status = QRACEL_ROUND_RESOLVED;
                locals.round.resolvedTick = qpi.tick();
                locals.round.nextOracleRetryTick = 0;

                locals.durationIndex = durationToIndex(locals.round.durationType);
                if (locals.durationIndex < QRACEL_DURATION_COUNT && state.get().activeRoundByDuration.get(locals.durationIndex) == locals.queryContext.roundIndex)
                {
                    state.mut().activeRoundByDuration.set(locals.durationIndex, QRACEL_NO_ROUND);
                }
            }
            else
            {
                locals.round.status = QRACEL_ROUND_WAIT_END;
                locals.round.nextOracleRetryTick = qpi.tick() + QRACEL_ORACLE_RETRY_TICKS;
            }

            state.mut().rounds.set(locals.queryContext.roundIndex, locals.round);
        }
    }

    PUBLIC_FUNCTION_WITH_LOCALS(GetRound)
    {
        output.found = 0;
        output.durationType = 0;
        output.status = 0;
        output.winningSide = QRACEL_SIDE_NONE;
        output.startTick = 0;
        output.endTick = 0;
        output.resolvedTick = 0;
        output.betCount = 0;
        output.upPool = 0;
        output.downPool = 0;
        output.totalPool = 0;
        output.startNumerator = 0;
        output.startDenominator = 0;
        output.endNumerator = 0;
        output.endDenominator = 0;
        output.startQueryId = 0;
        output.endQueryId = 0;

        if (!state.get().roundIdToIndex.get(input.roundId, locals.roundIndex))
            return;

        if (locals.roundIndex >= state.get().roundCount)
            return;

        locals.round = state.get().rounds.get(locals.roundIndex);
        output.found = 1;
        output.durationType = locals.round.durationType;
        output.status = locals.round.status;
        output.winningSide = locals.round.winningSide;
        output.startTick = locals.round.startTick;
        output.endTick = locals.round.endTick;
        output.resolvedTick = locals.round.resolvedTick;
        output.betCount = locals.round.betCount;
        output.upPool = locals.round.upPool;
        output.downPool = locals.round.downPool;
        output.totalPool = locals.round.totalPool;
        output.startNumerator = locals.round.startNumerator;
        output.startDenominator = locals.round.startDenominator;
        output.endNumerator = locals.round.endNumerator;
        output.endDenominator = locals.round.endDenominator;
        output.startQueryId = locals.round.startQueryId;
        output.endQueryId = locals.round.endQueryId;
    }

    PUBLIC_FUNCTION_WITH_LOCALS(GetBet)
    {
        output.found = 0;
        output.side = QRACEL_SIDE_NONE;
        output.claimed = 0;
        output.roundStatus = 0;
        output.roundWinningSide = QRACEL_SIDE_NONE;
        output.roundIndex = 0;
        output.amount = 0;
        output.roundId = 0;
        output.bettor = NULL_ID;

        if (input.betId >= state.get().betCount)
            return;

        locals.bet = state.get().bets.get(input.betId);
        if (locals.bet.roundIndex >= state.get().roundCount)
            return;

        locals.round = state.get().rounds.get(locals.bet.roundIndex);

        output.found = 1;
        output.side = locals.bet.side;
        output.claimed = locals.bet.claimed;
        output.roundStatus = locals.round.status;
        output.roundWinningSide = locals.round.winningSide;
        output.roundIndex = locals.bet.roundIndex;
        output.amount = locals.bet.amount;
        output.roundId = locals.round.roundId;
        output.bettor = locals.bet.bettor;
    }

    PUBLIC_FUNCTION_WITH_LOCALS(GetConfig)
    {
        output.admin = state.get().admin;
        output.oracleId = state.get().oracleId;
        output.autoCreate = state.get().autoCreate;
        output._pad0 = 0;
        output._pad1 = 0;
        output._pad2 = 0;
        output.minBet = QRACEL_MIN_BET;
        output.roundCount = state.get().roundCount;
        output.betCount = state.get().betCount;
        output.nextRoundId = state.get().nextRoundId;
        output.totalVolume = state.get().totalVolume;
        output.totalPayouts = state.get().totalPayouts;

        output.activeRound10m = 0;
        output.activeRound60m = 0;
        output.activeRound6h = 0;
        output.activeRound24h = 0;
        output.dbgLastQueryId = state.get().dbgLastQueryId;
        output.dbgCreateRoundCalls = state.get().dbgCreateRoundCalls;
        output.dbgOracleFails = state.get().dbgOracleFails;
        output.dbgLastStatus = state.get().dbgLastStatus;
        output._dbgPad0 = 0;
        output._dbgPad1 = 0;
        output.dbgActiveRaw = state.get().dbgActiveRaw;
        output.dbgEndTickAutoCreates = state.get().dbgEndTickAutoCreates;

        locals.idx = state.get().activeRoundByDuration.get(durationToIndex(QRACEL_DURATION_10M));
        if (locals.idx != QRACEL_NO_ROUND && locals.idx < state.get().roundCount)
            output.activeRound10m = state.get().rounds.get(locals.idx).roundId;

        locals.idx = state.get().activeRoundByDuration.get(durationToIndex(QRACEL_DURATION_60M));
        if (locals.idx != QRACEL_NO_ROUND && locals.idx < state.get().roundCount)
            output.activeRound60m = state.get().rounds.get(locals.idx).roundId;

        locals.idx = state.get().activeRoundByDuration.get(durationToIndex(QRACEL_DURATION_6H));
        if (locals.idx != QRACEL_NO_ROUND && locals.idx < state.get().roundCount)
            output.activeRound6h = state.get().rounds.get(locals.idx).roundId;

        locals.idx = state.get().activeRoundByDuration.get(durationToIndex(QRACEL_DURATION_24H));
        if (locals.idx != QRACEL_NO_ROUND && locals.idx < state.get().roundCount)
            output.activeRound24h = state.get().rounds.get(locals.idx).roundId;
    }

    PUBLIC_FUNCTION_WITH_LOCALS(GetActiveRound)
    {
        output.found = 0;
        output.durationType = input.durationType;
        output.status = 0;
        output.startTick = 0;
        output.endTick = 0;
        output.roundId = 0;

        if (!isValidDuration(input.durationType))
            return;

        locals.durationIndex = durationToIndex(input.durationType);
        locals.roundIndex = state.get().activeRoundByDuration.get(locals.durationIndex);
        if (locals.roundIndex == QRACEL_NO_ROUND || locals.roundIndex >= state.get().roundCount)
            return;

        locals.round = state.get().rounds.get(locals.roundIndex);
        output.found = 1;
        output.durationType = locals.round.durationType;
        output.status = locals.round.status;
        output.startTick = locals.round.startTick;
        output.endTick = locals.round.endTick;
        output.roundId = locals.round.roundId;
    }

    INITIALIZE_WITH_LOCALS()
    {
        state.mut().admin = ID(
            _Z, _P, _L, _F, _Z, _L, _F, _X, _C, _A, _X, _N, _Z, _F,
            _T, _N, _P, _V, _W, _U, _I, _L, _A, _O, _N, _J, _N, _B,
            _L, _D, _J, _D, _H, _O, _U, _I, _N, _K, _E, _Y, _X, _B,
            _V, _I, _T, _A, _D, _M, _W, _G, _X, _H, _H, _Q, _E, _G
        );
        state.mut().oracleId = OI::Price::getBinanceOracleId();
        state.mut().autoCreate = 0;
        state.mut()._pad0 = 0;
        state.mut()._pad1 = 0;
        state.mut()._pad2 = 0;
        state.mut().roundCount = 0;
        state.mut().betCount = 0;
        state.mut().nextRoundId = 0;
        state.mut().totalVolume = 0;
        state.mut().totalPayouts = 0;
        state.mut().roundIdToIndex.reset();
        state.mut().oracleQueryContext.reset();

        for (locals.i = 0; locals.i < QRACEL_DURATION_COUNT; ++locals.i)
        {
            state.mut().activeRoundByDuration.set(locals.i, QRACEL_NO_ROUND);
        }
    }

    BEGIN_EPOCH()
    {
    }

    END_EPOCH()
    {
        state.mut().oracleQueryContext.cleanupIfNeeded();
    }

    BEGIN_TICK()
    {
    }

    END_TICK_WITH_LOCALS()
    {
        for (locals.i = 0; locals.i < QRACEL_DURATION_COUNT; ++locals.i)
        {
            locals.durationType = locals.i + 1;
            locals.durationIndex = locals.i;
            locals.roundIndex = state.get().activeRoundByDuration.get(locals.durationIndex);

            if (locals.roundIndex == QRACEL_NO_ROUND)
            {
                if (!(state.get().autoCreate & (1 << locals.durationIndex)))
                    continue;

                if (state.get().roundCount >= QRACEL_MAX_ROUNDS)
                    continue;

                // Only auto-create at clean time boundaries:
                // 10m -> minute % 10 == 0, 60m -> minute == 0,
                // 6h  -> minute == 0 && hour % 6 == 0, 24h -> minute == 0 && hour == 0
                if (locals.durationType == QRACEL_DURATION_10M && (qpi.minute() % 10) != 0)
                    continue;
                if (locals.durationType == QRACEL_DURATION_60M && qpi.minute() != 0)
                    continue;
                if (locals.durationType == QRACEL_DURATION_6H && (qpi.minute() != 0 || (qpi.hour() % 6) != 0))
                    continue;
                if (locals.durationType == QRACEL_DURATION_24H && (qpi.minute() != 0 || qpi.hour() != 0))
                    continue;

                locals.durationTicks = durationToTicks(locals.durationType);
                if (locals.durationTicks == 0)
                    continue;

                locals.roundIndex = state.get().roundCount;
                locals.round.roundId = state.get().nextRoundId + 1;
                locals.round.durationTicks = locals.durationTicks;
                locals.round.startTick = qpi.tick();
                locals.round.endTick = qpi.tick() + locals.durationTicks;
                locals.round.resolvedTick = 0;
                locals.round.betCount = 0;
                locals.round.upPool = 0;
                locals.round.downPool = 0;
                locals.round.totalPool = 0;
                locals.round.startNumerator = 0;
                locals.round.startDenominator = 0;
                locals.round.endNumerator = 0;
                locals.round.endDenominator = 0;
                locals.round.startQueryId = 0;
                locals.round.endQueryId = 0;
                locals.round.nextOracleRetryTick = 0;
                locals.round.durationType = locals.durationType;
                locals.round.status = QRACEL_ROUND_WAIT_START;
                locals.round.winningSide = QRACEL_SIDE_NONE;
                locals.round._pad0 = 0;

                setupBtcUsdtQuery(state.get().oracleId, qpi.now(), locals.query);
                locals.queryId = QUERY_ORACLE(OI::Price, locals.query, NotifyPriceOracleReply, QRACEL_ORACLE_TIMEOUT_MS);
                if (locals.queryId < 0)
                    continue;

                locals.round.startQueryId = locals.queryId;
                state.mut().rounds.set(locals.roundIndex, locals.round);
                state.mut().roundIdToIndex.set(locals.round.roundId, locals.roundIndex);

                locals.queryContext.roundIndex = locals.roundIndex;
                locals.queryContext.phase = QRACEL_QUERY_PHASE_START;
                locals.queryContext._pad0 = 0;
                locals.queryContext._pad1 = 0;
                state.mut().oracleQueryContext.set((uint64)locals.queryId, locals.queryContext);

                state.mut().activeRoundByDuration.set(locals.durationIndex, locals.roundIndex);
                state.mut().roundCount = state.get().roundCount + 1;
                state.mut().nextRoundId = locals.round.roundId;
                state.mut().dbgEndTickAutoCreates = state.get().dbgEndTickAutoCreates + 1;
                continue;
            }

            if (locals.roundIndex >= state.get().roundCount)
            {
                state.mut().activeRoundByDuration.set(locals.durationIndex, QRACEL_NO_ROUND);
                continue;
            }

            locals.round = state.get().rounds.get(locals.roundIndex);

            if (locals.round.status == QRACEL_ROUND_WAIT_START && locals.round.startQueryId == 0 && qpi.tick() >= locals.round.nextOracleRetryTick)
            {
                setupBtcUsdtQuery(state.get().oracleId, qpi.now(), locals.query);
                locals.queryId = QUERY_ORACLE(OI::Price, locals.query, NotifyPriceOracleReply, QRACEL_ORACLE_TIMEOUT_MS);
                if (locals.queryId < 0)
                {
                    locals.round.nextOracleRetryTick = qpi.tick() + QRACEL_ORACLE_RETRY_TICKS;
                }
                else
                {
                    locals.round.startQueryId = locals.queryId;
                    locals.queryContext.roundIndex = locals.roundIndex;
                    locals.queryContext.phase = QRACEL_QUERY_PHASE_START;
                    locals.queryContext._pad0 = 0;
                    locals.queryContext._pad1 = 0;
                    state.mut().oracleQueryContext.set((uint64)locals.queryId, locals.queryContext);
                }

                state.mut().rounds.set(locals.roundIndex, locals.round);
                continue;
            }

            if ((locals.round.status == QRACEL_ROUND_OPEN || locals.round.status == QRACEL_ROUND_WAIT_END)
                && qpi.tick() >= locals.round.endTick
                && locals.round.endQueryId == 0
                && (locals.round.status != QRACEL_ROUND_WAIT_END || qpi.tick() >= locals.round.nextOracleRetryTick))
            {
                setupBtcUsdtQuery(state.get().oracleId, qpi.now(), locals.query);
                locals.queryId = QUERY_ORACLE(OI::Price, locals.query, NotifyPriceOracleReply, QRACEL_ORACLE_TIMEOUT_MS);
                if (locals.queryId < 0)
                {
                    locals.round.status = QRACEL_ROUND_WAIT_END;
                    locals.round.nextOracleRetryTick = qpi.tick() + QRACEL_ORACLE_RETRY_TICKS;
                }
                else
                {
                    locals.round.status = QRACEL_ROUND_WAIT_END;
                    locals.round.endQueryId = locals.queryId;
                    locals.round.nextOracleRetryTick = 0;

                    locals.queryContext.roundIndex = locals.roundIndex;
                    locals.queryContext.phase = QRACEL_QUERY_PHASE_END;
                    locals.queryContext._pad0 = 0;
                    locals.queryContext._pad1 = 0;
                    state.mut().oracleQueryContext.set((uint64)locals.queryId, locals.queryContext);
                }

                state.mut().rounds.set(locals.roundIndex, locals.round);
            }
        }
    }

    PRE_ACQUIRE_SHARES()
    {
    }

    POST_ACQUIRE_SHARES()
    {
    }

    PRE_RELEASE_SHARES()
    {
    }

    POST_RELEASE_SHARES()
    {
    }

    POST_INCOMING_TRANSFER()
    {
    }

    EXPAND()
    }
};