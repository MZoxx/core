using namespace QPI;

constexpr uint64 QRACEL_MAX_ROUNDS = 16384;
constexpr uint64 QRACEL_MAX_BETS = 65536;
constexpr uint64 QRACEL_MIN_BET = 1000000;
constexpr uint64 QRACEL_MAX_TRANSFERABLE = 9223372036854775807ULL;

constexpr uint8 QRACEL_DURATION_10M = 1;
constexpr uint8 QRACEL_DURATION_60M = 2;
constexpr uint8 QRACEL_DURATION_6H = 3;
constexpr uint8 QRACEL_DURATION_24H = 4;
constexpr uint8 QRACEL_DURATION_1M = 5;
constexpr uint8 QRACEL_DURATION_COUNT = 5;
constexpr uint8 QRACEL_DURATION_CAPACITY = 8;
constexpr uint8 QRACEL_MAX_PENDING_SLOTS = 10;
constexpr uint32 QRACEL_TOTAL_PENDING_SLOTS = 50;
constexpr uint32 QRACEL_PENDING_CAPACITY = 64;

constexpr uint8 QRACEL_SIDE_NONE = 0;
constexpr uint8 QRACEL_SIDE_UP = 1;
constexpr uint8 QRACEL_SIDE_DOWN = 2;
constexpr uint8 QRACEL_SIDE_DRAW = 3;

constexpr uint8 QRACEL_ROUND_WAIT_START = 1;
constexpr uint8 QRACEL_ROUND_OPEN = 2;
constexpr uint8 QRACEL_ROUND_WAIT_END = 3;
constexpr uint8 QRACEL_ROUND_RESOLVED = 4;
constexpr uint8 QRACEL_ROUND_PENDING = 5;

constexpr uint32 QRACEL_ORACLE_TIMEOUT_MS = 120000;
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
        uint8 startHour;
        uint8 startMinute;
        uint8 endHour;
        uint8 endMinute;
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

    struct StateData
    {
        id admin;
        id oracleId;
        uint8 autoCreate;
        uint8 lastQueryHour;
        uint8 lastQueryMinute;
        uint8 pendingPriceHour;
        uint8 pendingPriceMinute;
        uint8 _pad0;
        uint16 _pad1;
        uint32 roundCount;
        uint32 betCount;
        uint64 nextRoundId;
        uint64 totalVolume;
        uint64 totalPayouts;
        sint64 pendingPriceQueryId;
        sint64 dbgLastQueryId;
        uint32 dbgCreateRoundCalls;
        uint32 dbgOracleFails;
        uint8 dbgLastStatus;
        uint8 _dbgPad0;
        uint16 _dbgPad1;
        uint32 dbgActiveRaw;
        uint32 dbgEndTickAutoCreates;
        Array<uint8, QRACEL_DURATION_CAPACITY> pendingCounts;
        Array<uint32, QRACEL_PENDING_CAPACITY> pendingRounds;
        Array<RoundData, QRACEL_MAX_ROUNDS> rounds;
        Array<BetData, QRACEL_MAX_BETS> bets;
        Array<uint32, QRACEL_DURATION_CAPACITY> activeRoundByDuration;
        HashMap<uint64, uint32, QRACEL_MAX_ROUNDS> roundIdToIndex;
    };

    StateData _stateData;
    const StateData& get() const { return _stateData; }
    StateData& mut() { return _stateData; }

    static bool isValidDuration(uint8 durationType)
    {
        return (durationType >= QRACEL_DURATION_10M && durationType <= QRACEL_DURATION_24H) || durationType == QRACEL_DURATION_1M;
    }

    static uint32 durationToIndex(uint8 durationType)
    {
        return durationType - 1;
    }

    static void computeRoundEndTime(uint8 durationType, uint8 startHour, uint8 startMinute, uint8& endHour, uint8& endMinute)
    {
        endHour = startHour;
        endMinute = startMinute;

        if (durationType == QRACEL_DURATION_1M)
        {
            endMinute = startMinute + 1;
            if (endMinute >= 60) { endMinute -= 60; endHour += 1; }
        }
        else if (durationType == QRACEL_DURATION_10M)
        {
            endMinute = startMinute + 10;
            if (endMinute >= 60) { endMinute -= 60; endHour += 1; }
        }
        else if (durationType == QRACEL_DURATION_60M)
        {
            endHour = startHour + 1;
            endMinute = 0;
        }
        else if (durationType == QRACEL_DURATION_6H)
        {
            endHour = startHour + 6;
            endMinute = 0;
        }
        else // 24H
        {
            endMinute = 0;
            endHour = startHour + 24;
        }

        if (endHour >= 24) endHour -= 24;
    }

    static bool hasTimeArrived(uint8 curH, uint8 curM, uint8 targetH, uint8 targetM)
    {
        return ((uint16)curH * 60 + curM) >= ((uint16)targetH * 60 + targetM);
    }

    static bool isRoundTimeExpired(uint8 curH, uint8 curM, uint8 endH, uint8 endM, uint8 startH, uint8 startM)
    {
        if (((uint16)endH * 60 + endM) > ((uint16)startH * 60 + startM))
            return ((uint16)curH * 60 + curM) >= ((uint16)endH * 60 + endM);
        if (((uint16)endH * 60 + endM) < ((uint16)startH * 60 + startM))
            return ((uint16)curH * 60 + curM) >= ((uint16)endH * 60 + endM) && ((uint16)curH * 60 + curM) < ((uint16)startH * 60 + startM);
        return false;
    }

    static void setupBtcUsdtQuery(const id& oracleId, const DateAndTime& timestamp, OI::Price::OracleQuery& query)
    {
        using namespace Ch;
        query.oracle = oracleId;
        query.timestamp = timestamp;
        query.currency1 = id(B, T, C, null, null);
        query.currency2 = id(U, S, D, T, null);
    }

    static void computeNextBoundary(uint8 durationType, uint8 curH, uint8 curM, uint8& nextH, uint8& nextM)
    {
        nextH = curH;
        nextM = 0;
        if (durationType == QRACEL_DURATION_1M)
        {
            nextM = curM + 1;
            if (nextM >= 60) { nextM = 0; nextH = curH + 1; }
        }
        else if (durationType == QRACEL_DURATION_10M)
        {
            nextM = (div((uint32)curM, (uint32)10) + 1) * 10;
            if (nextM >= 60) { nextM = nextM - 60; nextH = curH + 1; }
        }
        else if (durationType == QRACEL_DURATION_60M)
        {
            nextH = curH + 1;
        }
        else if (durationType == QRACEL_DURATION_6H)
        {
            nextH = (div((uint32)curH, (uint32)6) + 1) * 6;
        }
        else
        {
            nextH = 0;
        }
        if (nextH >= 24) nextH = nextH - 24;
    }

    static bool isBoundaryForDuration(uint8 durationType, uint8 hour, uint8 minute)
    {
        if (durationType == QRACEL_DURATION_1M) return true;
        if (durationType == QRACEL_DURATION_10M) return mod((uint32)minute, (uint32)10) == 0;
        if (durationType == QRACEL_DURATION_60M) return minute == 0;
        if (durationType == QRACEL_DURATION_6H) return minute == 0 && mod((uint32)hour, (uint32)6) == 0;
        if (durationType == QRACEL_DURATION_24H) return minute == 0 && hour == 0;
        return false;
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
        uint8 startHour;
        uint8 startMinute;
        uint8 _pad0;
        uint32 _pad1;
    };
    struct CreateRound_output
    {
        uint8 status;
        uint8 startHour;
        uint8 startMinute;
        uint8 endHour;
        uint8 endMinute;
        uint8 _pad0;
        uint16 _pad1;
        uint64 roundId;
        sint64 startQueryId;
    };
    struct CreateRound_locals
    {
        uint32 durationIndex;
        uint32 roundIndex;
        RoundData round;
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
        uint8 startHour;
        uint8 startMinute;
        uint8 endHour;
        uint8 endMinute;
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
        uint64 activeRound1m;
        uint64 activeRound10m;
        uint64 activeRound60m;
        uint64 activeRound6h;
        uint64 activeRound24h;
        uint64 pendingRound1m;
        uint64 pendingRound10m;
        uint64 pendingRound60m;
        uint64 pendingRound6h;
        uint64 pendingRound24h;
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
        uint8 startHour;
        uint8 startMinute;
        uint8 endHour;
        uint8 endMinute;
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
        uint8 qH;
        uint8 qM;
        uint8 d;
        uint8 durationType;
        uint32 durationIndex;
        uint32 activeIdx;
        uint32 pendingIdx;
        uint32 s;
        uint32 slotBase;
        RoundData round;
        uint64 lhs;
        uint64 rhs;
        uint32 betIdx;
        BetData curBet;
        uint64 winnerPool;
        uint64 loserPool;
        uint64 bonus;
        uint64 payout;
        sint64 transferResult;
    };

    struct INITIALIZE_locals
    {
        uint32 i;
    };

    struct END_TICK_locals
    {
        uint8 d;
        uint8 durationType;
        uint8 nextH;
        uint8 nextM;
        uint32 durationIndex;
        uint32 roundIndex;
        uint32 maxPending;
        uint32 slotBase;
        uint32 p;
        RoundData round;
        OI::Price::OracleQuery query;
        sint64 queryId;
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
        // Rounds are created automatically by the contract
        output.status = QRACEL_STATUS_NOT_AUTHORIZED;
        output.roundId = 0;
        output.startHour = 0;
        output.startMinute = 0;
        output.endHour = 0;
        output.endMinute = 0;
        output.startQueryId = 0;
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
        if ((locals.round.status != QRACEL_ROUND_OPEN && locals.round.status != QRACEL_ROUND_PENDING)
            || isRoundTimeExpired(qpi.hour(), qpi.minute(), locals.round.endHour, locals.round.endMinute, locals.round.startHour, locals.round.startMinute))
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
        // Only accept replies for our pending shared query
        if (input.queryId != state.get().pendingPriceQueryId)
            return;

        state.mut().pendingPriceQueryId = 0;

        if (input.status != ORACLE_QUERY_STATUS_SUCCESS || !OI::Price::replyIsValid(input.reply))
        {
            state.mut().dbgOracleFails = state.get().dbgOracleFails + 1;
            return;
        }

        locals.qH = state.get().pendingPriceHour;
        locals.qM = state.get().pendingPriceMinute;
        state.mut().lastQueryHour = locals.qH;
        state.mut().lastQueryMinute = locals.qM;

        // For each duration: resolve active, then activate next pending
        for (locals.d = 0; locals.d < QRACEL_DURATION_COUNT; ++locals.d)
        {
            locals.durationType = locals.d + 1;
            locals.durationIndex = locals.d;

            if (!isBoundaryForDuration(locals.durationType, locals.qH, locals.qM))
                continue;

            // A) Resolve active round (set end price)
            locals.activeIdx = state.get().activeRoundByDuration.get(locals.durationIndex);
            if (locals.activeIdx != QRACEL_NO_ROUND && locals.activeIdx < state.get().roundCount)
            {
                locals.round = state.get().rounds.get(locals.activeIdx);
                if (locals.round.status == QRACEL_ROUND_OPEN)
                {
                    locals.round.endNumerator = input.reply.numerator;
                    locals.round.endDenominator = input.reply.denominator;
                    locals.round.endTick = qpi.tick();
                    locals.round.endQueryId = input.queryId;

                    locals.lhs = smul((uint64)locals.round.endNumerator, (uint64)locals.round.startDenominator);
                    locals.rhs = smul((uint64)locals.round.startNumerator, (uint64)locals.round.endDenominator);
                    if (locals.lhs > locals.rhs)
                        locals.round.winningSide = QRACEL_SIDE_UP;
                    else if (locals.lhs < locals.rhs)
                        locals.round.winningSide = QRACEL_SIDE_DOWN;
                    else
                        locals.round.winningSide = QRACEL_SIDE_DRAW;

                    if (locals.round.upPool == 0 || locals.round.downPool == 0)
                        locals.round.winningSide = QRACEL_SIDE_DRAW;

                    locals.round.status = QRACEL_ROUND_RESOLVED;
                    locals.round.resolvedTick = qpi.tick();
                    state.mut().rounds.set(locals.activeIdx, locals.round);
                    state.mut().activeRoundByDuration.set(locals.durationIndex, QRACEL_NO_ROUND);

                    // Auto-payout
                    for (locals.betIdx = 0; locals.betIdx < state.get().betCount; locals.betIdx = locals.betIdx + 1)
                    {
                        locals.curBet = state.get().bets.get(locals.betIdx);
                        if (locals.curBet.roundIndex != locals.activeIdx)
                            continue;
                        if (locals.curBet.claimed)
                            continue;

                        if (locals.round.winningSide == QRACEL_SIDE_DRAW)
                        {
                            locals.payout = locals.curBet.amount;
                        }
                        else if (locals.curBet.side != locals.round.winningSide)
                        {
                            locals.curBet.claimed = 1;
                            state.mut().bets.set(locals.betIdx, locals.curBet);
                            continue;
                        }
                        else
                        {
                            locals.winnerPool = (locals.round.winningSide == QRACEL_SIDE_UP) ? locals.round.upPool : locals.round.downPool;
                            if (locals.winnerPool == 0)
                            {
                                locals.payout = locals.curBet.amount;
                            }
                            else
                            {
                                locals.loserPool = locals.round.totalPool - locals.winnerPool;
                                locals.bonus = div<uint64>(smul(locals.curBet.amount, locals.loserPool), locals.winnerPool);
                                locals.payout = sadd(locals.curBet.amount, locals.bonus);
                            }
                        }

                        if (locals.payout > 0 && locals.payout <= QRACEL_MAX_TRANSFERABLE)
                        {
                            locals.transferResult = qpi.transfer(locals.curBet.bettor, (sint64)locals.payout);
                            if (locals.transferResult >= 0)
                            {
                                locals.curBet.claimed = 1;
                                state.mut().bets.set(locals.betIdx, locals.curBet);
                                state.mut().totalPayouts = sadd(state.get().totalPayouts, locals.payout);
                            }
                        }
                    }
                }
            }

            // B) Activate first pending round (set start price)
            if (state.get().activeRoundByDuration.get(locals.durationIndex) == QRACEL_NO_ROUND)
            {
                locals.slotBase = locals.durationIndex * QRACEL_MAX_PENDING_SLOTS;
                if (state.get().pendingCounts.get(locals.durationIndex) > 0)
                {
                    locals.pendingIdx = state.get().pendingRounds.get(locals.slotBase);
                    locals.round = state.get().rounds.get(locals.pendingIdx);

                    if (hasTimeArrived(locals.qH, locals.qM, locals.round.startHour, locals.round.startMinute))
                    {
                        locals.round.startNumerator = input.reply.numerator;
                        locals.round.startDenominator = input.reply.denominator;
                        locals.round.startTick = qpi.tick();
                        locals.round.startQueryId = input.queryId;
                        locals.round.status = QRACEL_ROUND_OPEN;
                        state.mut().rounds.set(locals.pendingIdx, locals.round);
                        state.mut().activeRoundByDuration.set(locals.durationIndex, locals.pendingIdx);

                        // Shift pending slots down
                        for (locals.s = 1; locals.s < (uint32)state.get().pendingCounts.get(locals.durationIndex); locals.s = locals.s + 1)
                        {
                            state.mut().pendingRounds.set(
                                locals.slotBase + locals.s - 1,
                                state.get().pendingRounds.get(locals.slotBase + locals.s));
                        }
                        state.mut().pendingRounds.set(
                            locals.slotBase + (uint32)state.get().pendingCounts.get(locals.durationIndex) - 1,
                            QRACEL_NO_ROUND);
                        state.mut().pendingCounts.set(locals.durationIndex,
                            state.get().pendingCounts.get(locals.durationIndex) - 1);
                    }
                }
            }
        }
    }

    PUBLIC_FUNCTION_WITH_LOCALS(GetRound)
    {
        output.found = 0;
        output.durationType = 0;
        output.status = 0;
        output.winningSide = QRACEL_SIDE_NONE;
        output.startHour = 0;
        output.startMinute = 0;
        output.endHour = 0;
        output.endMinute = 0;
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
        output.startHour = locals.round.startHour;
        output.startMinute = locals.round.startMinute;
        output.endHour = locals.round.endHour;
        output.endMinute = locals.round.endMinute;
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

        output.activeRound1m = 0;
        output.activeRound10m = 0;
        output.activeRound60m = 0;
        output.activeRound6h = 0;
        output.activeRound24h = 0;
        output.pendingRound1m = 0;
        output.pendingRound10m = 0;
        output.pendingRound60m = 0;
        output.pendingRound6h = 0;
        output.pendingRound24h = 0;
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

        locals.idx = state.get().activeRoundByDuration.get(durationToIndex(QRACEL_DURATION_1M));
        if (locals.idx != QRACEL_NO_ROUND && locals.idx < state.get().roundCount)
            output.activeRound1m = state.get().rounds.get(locals.idx).roundId;

        // First pending for each duration (slot 0)
        if (state.get().pendingCounts.get(durationToIndex(QRACEL_DURATION_10M)) > 0)
        {
            locals.idx = state.get().pendingRounds.get(durationToIndex(QRACEL_DURATION_10M) * QRACEL_MAX_PENDING_SLOTS);
            if (locals.idx != QRACEL_NO_ROUND && locals.idx < state.get().roundCount)
                output.pendingRound10m = state.get().rounds.get(locals.idx).roundId;
        }
        if (state.get().pendingCounts.get(durationToIndex(QRACEL_DURATION_60M)) > 0)
        {
            locals.idx = state.get().pendingRounds.get(durationToIndex(QRACEL_DURATION_60M) * QRACEL_MAX_PENDING_SLOTS);
            if (locals.idx != QRACEL_NO_ROUND && locals.idx < state.get().roundCount)
                output.pendingRound60m = state.get().rounds.get(locals.idx).roundId;
        }
        if (state.get().pendingCounts.get(durationToIndex(QRACEL_DURATION_6H)) > 0)
        {
            locals.idx = state.get().pendingRounds.get(durationToIndex(QRACEL_DURATION_6H) * QRACEL_MAX_PENDING_SLOTS);
            if (locals.idx != QRACEL_NO_ROUND && locals.idx < state.get().roundCount)
                output.pendingRound6h = state.get().rounds.get(locals.idx).roundId;
        }
        if (state.get().pendingCounts.get(durationToIndex(QRACEL_DURATION_24H)) > 0)
        {
            locals.idx = state.get().pendingRounds.get(durationToIndex(QRACEL_DURATION_24H) * QRACEL_MAX_PENDING_SLOTS);
            if (locals.idx != QRACEL_NO_ROUND && locals.idx < state.get().roundCount)
                output.pendingRound24h = state.get().rounds.get(locals.idx).roundId;
        }
        if (state.get().pendingCounts.get(durationToIndex(QRACEL_DURATION_1M)) > 0)
        {
            locals.idx = state.get().pendingRounds.get(durationToIndex(QRACEL_DURATION_1M) * QRACEL_MAX_PENDING_SLOTS);
            if (locals.idx != QRACEL_NO_ROUND && locals.idx < state.get().roundCount)
                output.pendingRound1m = state.get().rounds.get(locals.idx).roundId;
        }
    }

    PUBLIC_FUNCTION_WITH_LOCALS(GetActiveRound)
    {
        output.found = 0;
        output.durationType = input.durationType;
        output.status = 0;
        output.startHour = 0;
        output.startMinute = 0;
        output.endHour = 0;
        output.endMinute = 0;
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
        output.startHour = locals.round.startHour;
        output.startMinute = locals.round.startMinute;
        output.endHour = locals.round.endHour;
        output.endMinute = locals.round.endMinute;
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
        state.mut().lastQueryHour = 255;
        state.mut().lastQueryMinute = 255;
        state.mut().pendingPriceHour = 0;
        state.mut().pendingPriceMinute = 0;
        state.mut()._pad0 = 0;
        state.mut()._pad1 = 0;
        state.mut().roundCount = 0;
        state.mut().betCount = 0;
        state.mut().nextRoundId = 0;
        state.mut().totalVolume = 0;
        state.mut().totalPayouts = 0;
        state.mut().pendingPriceQueryId = 0;
        state.mut().roundIdToIndex.reset();

        for (locals.i = 0; locals.i < QRACEL_DURATION_COUNT; ++locals.i)
        {
            state.mut().activeRoundByDuration.set(locals.i, QRACEL_NO_ROUND);
            state.mut().pendingCounts.set(locals.i, 0);
        }
        for (locals.i = 0; locals.i < QRACEL_TOTAL_PENDING_SLOTS; ++locals.i)
        {
            state.mut().pendingRounds.set(locals.i, QRACEL_NO_ROUND);
        }
    }

    BEGIN_EPOCH()
    {
    }

    END_EPOCH()
    {
    }

    BEGIN_TICK()
    {
    }

    END_TICK_WITH_LOCALS()
    {
        // Phase 1: Fire shared oracle query if minute changed
        if (state.get().pendingPriceQueryId == 0
            && (qpi.minute() != state.get().lastQueryMinute || qpi.hour() != state.get().lastQueryHour))
        {
            setupBtcUsdtQuery(state.get().oracleId, qpi.now(), locals.query);
            locals.queryId = QUERY_ORACLE(OI::Price, locals.query, NotifyPriceOracleReply, QRACEL_ORACLE_TIMEOUT_MS);
            if (locals.queryId >= 0)
            {
                state.mut().pendingPriceQueryId = locals.queryId;
                state.mut().pendingPriceHour = qpi.hour();
                state.mut().pendingPriceMinute = qpi.minute();
                state.mut().dbgLastQueryId = locals.queryId;
            }
        }

        // Phase 2: Fill pending rounds (up to 10 for 1m/10m, 1 for others)
        for (locals.d = 0; locals.d < QRACEL_DURATION_COUNT; ++locals.d)
        {
            locals.durationType = locals.d + 1;
            locals.durationIndex = locals.d;

            if (!(state.get().autoCreate & (1 << locals.durationIndex)))
                continue;

            locals.maxPending = 1;
            if (locals.durationType == QRACEL_DURATION_1M || locals.durationType == QRACEL_DURATION_10M)
                locals.maxPending = QRACEL_MAX_PENDING_SLOTS;

            locals.slotBase = locals.durationIndex * QRACEL_MAX_PENDING_SLOTS;

            for (locals.p = 0; locals.p < locals.maxPending; ++locals.p)
            {
                if ((uint32)state.get().pendingCounts.get(locals.durationIndex) >= locals.maxPending)
                    break;
                if (state.get().roundCount >= QRACEL_MAX_ROUNDS)
                    break;

                // Compute next boundary
                if (state.get().pendingCounts.get(locals.durationIndex) == 0)
                {
                    computeNextBoundary(locals.durationType, qpi.hour(), qpi.minute(), locals.nextH, locals.nextM);
                }
                else
                {
                    locals.roundIndex = state.get().pendingRounds.get(
                        locals.slotBase + (uint32)state.get().pendingCounts.get(locals.durationIndex) - 1);
                    locals.round = state.get().rounds.get(locals.roundIndex);
                    computeNextBoundary(locals.durationType, locals.round.startHour, locals.round.startMinute, locals.nextH, locals.nextM);
                }

                // Create PENDING round
                locals.roundIndex = state.get().roundCount;
                locals.round.roundId = state.get().nextRoundId + 1;
                locals.round.startTick = 0;
                locals.round.endTick = 0;
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
                locals.round.status = QRACEL_ROUND_PENDING;
                locals.round.winningSide = QRACEL_SIDE_NONE;
                locals.round.startHour = locals.nextH;
                locals.round.startMinute = locals.nextM;
                computeRoundEndTime(locals.durationType, locals.nextH, locals.nextM, locals.round.endHour, locals.round.endMinute);
                locals.round._pad0 = 0;

                state.mut().rounds.set(locals.roundIndex, locals.round);
                state.mut().roundIdToIndex.set(locals.round.roundId, locals.roundIndex);
                state.mut().pendingRounds.set(
                    locals.slotBase + (uint32)state.get().pendingCounts.get(locals.durationIndex),
                    locals.roundIndex);
                state.mut().pendingCounts.set(locals.durationIndex,
                    state.get().pendingCounts.get(locals.durationIndex) + 1);
                state.mut().roundCount = state.get().roundCount + 1;
                state.mut().nextRoundId = locals.round.roundId;
                state.mut().dbgEndTickAutoCreates = state.get().dbgEndTickAutoCreates + 1;
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
};