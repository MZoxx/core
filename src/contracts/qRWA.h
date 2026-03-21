using namespace QPI;

/***************************************************/
/******************* CONSTANTS *********************/
/***************************************************/

constexpr uint64 QRWA_MAX_QMINE_HOLDERS = 131072 * X_MULTIPLIER; // 2^17 = 128K unique holders max (563MB → 37MB state)
constexpr uint64 QRWA_MAX_GOV_POLLS = 64; // 8 active polls * 8 epochs = 64 slots

constexpr uint64 QRWA_MAX_ASSETS = 1024; // 2^10

constexpr uint64 QRWA_MAX_NEW_GOV_POLLS_PER_EPOCH = 8;


// Dividend percentage constants
constexpr uint64 QRWA_QMINE_HOLDER_PERCENT = 900; // 90.0%
constexpr uint64 QRWA_QRWA_HOLDER_PERCENT = 100;  // 10.0%
constexpr uint64 QRWA_PERCENT_DENOMINATOR = 1000; // 100.0%
constexpr uint64 QRWA_QMINE_PER_QRWA_SHARE_MIN = 100000ULL;
constexpr uint64 QRWA_CONTRACT_ASSET_NAME = 1096241745ULL; // assetNameFromString("QRWA")

// Payout Timing Constants
constexpr uint64 QRWA_PAYOUT_DAY = FRIDAY; // Friday (Production)
constexpr uint64 QRWA_PAYOUT_HOUR = 12; // 12:00 PM UTC (Production)
constexpr uint64 QRWA_MIN_PAYOUT_INTERVAL_MS = 6 * 86400000LL; // 6 days in milliseconds (Production)
constexpr uint64 QRWA_PAYOUT_TICK_INTERVAL = 20; // TESTING: Check every 20 ticks for payout

// STATUS CODES for Procedures
constexpr uint64 QRWA_STATUS_SUCCESS = 1;
constexpr uint64 QRWA_STATUS_FAILURE_GENERAL = 0;
constexpr uint64 QRWA_STATUS_FAILURE_INSUFFICIENT_FEE = 2;
constexpr uint64 QRWA_STATUS_FAILURE_INVALID_INPUT = 3;
constexpr uint64 QRWA_STATUS_FAILURE_NOT_AUTHORIZED = 4;
constexpr uint64 QRWA_STATUS_FAILURE_INSUFFICIENT_BALANCE = 5;
constexpr uint64 QRWA_STATUS_FAILURE_LIMIT_REACHED = 6;
constexpr uint64 QRWA_STATUS_FAILURE_TRANSFER_FAILED = 7;
constexpr uint64 QRWA_STATUS_FAILURE_NOT_FOUND = 8;
constexpr uint64 QRWA_STATUS_FAILURE_ALREADY_VOTED = 9;
constexpr uint64 QRWA_STATUS_FAILURE_POLL_INACTIVE = 10;
constexpr uint64 QRWA_STATUS_FAILURE_WRONG_STATE = 11;

constexpr uint64 QRWA_POLL_STATUS_EMPTY = 0;
constexpr uint64 QRWA_POLL_STATUS_ACTIVE = 1; // poll is live, can be voted
constexpr uint64 QRWA_POLL_STATUS_PASSED_EXECUTED = 2; // poll inactive, result is YES
constexpr uint64 QRWA_POLL_STATUS_FAILED_VOTE = 3; // poll inactive, result is NO


// QX Fee for releasing management rights
constexpr sint64 QRWA_RELEASE_MANAGEMENT_FEE = 100;

// LOG TYPES
constexpr uint64 QRWA_LOG_TYPE_DISTRIBUTION = 1;
constexpr uint64 QRWA_LOG_TYPE_GOV_VOTE = 2;

constexpr uint64 QRWA_LOG_TYPE_TREASURY_DONATION = 6;
constexpr uint64 QRWA_LOG_TYPE_ADMIN_ACTION = 7;
constexpr uint64 QRWA_LOG_TYPE_ERROR = 8;
constexpr uint64 QRWA_LOG_TYPE_INCOMING_REVENUE_A = 9;
constexpr uint64 QRWA_LOG_TYPE_INCOMING_REVENUE_B = 10;
constexpr uint64 QRWA_LOG_TYPE_INCOMING_REVENUE_DEDICATED = 11;
constexpr uint64 QRWA_LOG_TYPE_PAYOUT_QMINE_HOLDER = 12; // valueA=amount, valueB=eligible QMINE count
constexpr uint64 QRWA_LOG_TYPE_PAYOUT_QRWA_HOLDER = 13; // valueA=amount, valueB=qRWA shares
constexpr uint64 QRWA_LOG_TYPE_PAYOUT_DEDICATED_QRWA = 14; // valueA=amount, valueB=qRWA shares (Pool C leg)
constexpr uint64 QRWA_LOG_TYPE_INCOMING_SC_DIVIDEND = 15; // SC dividend received → Pool B; valueA=amount, valueB=cumulative

// Ring buffer for tracking the last N individual payouts (queryable via GetLatestPayouts = fn 11)
constexpr uint64 QRWA_PAYOUT_RING_SIZE = 8192; // Must be a power of 2
constexpr uint8 QRWA_PAYOUT_TYPE_QMINE_HOLDER    = 0; // Regular QMINE holder payout
constexpr uint8 QRWA_PAYOUT_TYPE_QMINE_DEV       = 1; // Dev address gets reducer's portion
constexpr uint8 QRWA_PAYOUT_TYPE_QRWA_HOLDER     = 2; // qRWA shareholder (Pool B)
constexpr uint8 QRWA_PAYOUT_TYPE_DEDICATED_QRWA  = 3; // Pool C (BTC Mining) dedicated qRWA holder leg




/***************************************************/
/**************** CONTRACT STATE *******************/
/***************************************************/

struct QRWA2
{
};

struct QRWA : public ContractBase
{
    friend class ContractTestingQRWA;
    /***************************************************/
    /******************** STRUCTS **********************/
    /***************************************************/

    struct QRWAAsset
    {
        id issuer;
        uint64 assetName;

        operator Asset() const
        {
            return { issuer, assetName };
        }

        bool operator==(const QRWAAsset other) const
        {
            return issuer == other.issuer && assetName == other.assetName;
        }

        bool operator!=(const QRWAAsset other) const
        {
            return issuer != other.issuer || assetName != other.assetName;
        }

        inline void setFrom(const Asset& asset)
        {
            issuer = asset.issuer;
            assetName = asset.assetName;
        }
    };

    // votable governance parameters for the contract.
    struct QRWAGovParams
    {
        // Addresses
        id mAdminAddress; // Only the admin can create release polls
        // Addresses to receive the MINING FEEs
        id electricityAddress;
        id maintenanceAddress;
        id reinvestmentAddress;
        id qmineDevAddress; // Address to receive rewards for moved QMINE during epoch

        // MINING FEE Percentages
        uint64 electricityPercent;
        uint64 maintenancePercent;
        uint64 reinvestmentPercent;
    };

    // Represents a governance poll in a rotating buffer
    struct QRWAGovProposal
    {
        uint64 proposalId; // The unique, increasing ID
        uint64 status; // 0=Empty, 1=Active, 2=Passed, 3=Failed
        uint64 score; // Final score, count at END_EPOCH
        QRWAGovParams params; // The actual proposal data
    };



    // Logger for general contract events.
    struct QRWALogger
    {
        uint64 contractId;
        uint64 logType;
        id primaryId; // voter, asset issuer, proposal creator
        uint64 valueA;
        uint64 valueB;
        sint8 _terminator;
    };

    // Single entry in the per-pool payout ring buffers (mPayoutsPoolA, mPayoutsPoolB, mPayoutsPoolC).
    struct QRWAPayoutEntry
    {
        id recipient;          // Who received the payment
        uint64 amount;         // Amount in QU
        uint64 qmineHolding;   // Recipient's QMINE shares at payout time
        uint64 qrwaHolding;    // Recipient's qRWA shares at payout time
        uint32 tick;           // Network tick of the payout
        uint16 epoch;          // Epoch of the payout
        uint8 payoutType;      // QRWA_PAYOUT_TYPE_* constant
        uint8 _pad0;
    };



protected:
    Asset mQmineAsset;

    // QMINE Shareholder Tracking
    HashMap<id, uint64, QRWA_MAX_QMINE_HOLDERS> mBeginEpochBalances;
    HashMap<id, uint64, QRWA_MAX_QMINE_HOLDERS> mEndEpochBalances;
    uint64 mTotalQmineBeginEpoch; // Total QMINE shares at the start of the current epoch

    // PAYOUT SNAPSHOTS (for distribution)
    // These hold the data from the last epoch, saved at END_EPOCH
    HashMap<id, uint64, QRWA_MAX_QMINE_HOLDERS> mPayoutBeginBalances;
    HashMap<id, uint64, QRWA_MAX_QMINE_HOLDERS> mPayoutEndBalances;
    uint64 mPayoutTotalQmineBegin; // Total QMINE shares from the last epoch's beginning

    // Votable Parameters
    QRWAGovParams mCurrentGovParams; // The live, active parameters

    // Voting state for governance parameters (voted by QMINE holders)
    Array<QRWAGovProposal, QRWA_MAX_GOV_POLLS> mGovPolls;
    HashMap<id, uint64, QRWA_MAX_QMINE_HOLDERS> mShareholderVoteMap; // Maps QMINE holder -> Gov Poll slot index
    uint64 mCurrentGovProposalId;
    uint64 mNewGovPollsThisEpoch;



    // Treasury & Asset Release
    uint64 mTreasuryBalance; // QMINE token balance holds by SC
    HashMap<QRWAAsset, uint64, QRWA_MAX_ASSETS> mGeneralAssetBalances; // Balances for other assets (e.g., SC shares)
    HashMap<id, uint64, QRWA_MAX_ASSETS> mScDividendTracker; // SC contract ID → cumulative dividends received (routed to Pool B)

    // Payouts and Dividend Accounting
    DateAndTime mLastPayoutTime; // Tracks the last payout time (Production)
    uint64 mLastPayoutTick; // TESTING: Tick-based payout tracking

    // Revenue Pools (incoming, before splitting into QMINE/qRWA)
    uint64 mRevenuePoolA; // Mined funds from Qubic farm (from SCs) — gov fees deducted first
    uint64 mRevenuePoolB; // Other dividend funds (from user wallets) — no gov fees
    uint64 mDedicatedRevenuePool; // Pool C (BTC Mining) revenue from dedicated address

    // Per-pool dividend sub-pools (populated from revenue, split 90% QMINE / 10% qRWA)
    uint64 mPoolAQmineDividend;    // 90% of Pool A revenue (after gov fees)
    uint64 mPoolAQrwaDividend;     // 10% of Pool A revenue (after gov fees)
    uint64 mPoolBQmineDividend;    // 90% of Pool B revenue (no gov fees)
    uint64 mPoolBQrwaDividend;     // 10% of Pool B revenue (no gov fees)
    uint64 mPoolCQmineDividend;    // 90% of Pool C revenue
    uint64 mPoolCQrwaDividend;     // 10% of Pool C revenue (dedicated, requires >= 100K QMINE/share)

    // Pool C (BTC Mining) revenue configuration
    id mDedicatedRevenueAddress;

    // Pool A revenue address (QMINE issuer or configured mining address)
    id mPoolARevenueAddress;

    // Fundraising address — excluded from ALL distributions
    id mFundraisingAddress;

    // Per-pool total distributed tracking
    uint64 mTotalPoolADistributed;
    uint64 mTotalPoolBDistributed;
    uint64 mTotalPoolCDistributed;

    // Per-pool ring buffers (one per pool, each contains all payout types for that pool)
    Array<QRWAPayoutEntry, QRWA_PAYOUT_RING_SIZE> mPayoutsPoolA;   // Pool A: QMINE + qRWA payouts
    uint16 mPayoutsPoolANextIdx;
    Array<QRWAPayoutEntry, QRWA_PAYOUT_RING_SIZE> mPayoutsPoolB;   // Pool B: QMINE + qRWA payouts
    uint16 mPayoutsPoolBNextIdx;
    Array<QRWAPayoutEntry, QRWA_PAYOUT_RING_SIZE> mPayoutsPoolC;   // Pool C: QMINE + dedicated qRWA payouts
    uint16 mPayoutsPoolCNextIdx;



public:
    /***************************************************/
    /**************** PUBLIC PROCEDURES ****************/
    /***************************************************/

    // Treasury
    struct DonateToTreasury_input
    {
        uint64 amount;
    };
    struct DonateToTreasury_output
    {
        uint64 status;
    };
    struct DonateToTreasury_locals
    {
        sint64 transferResult;
        sint64 balance;
        QRWALogger logger;
    };
    PUBLIC_PROCEDURE_WITH_LOCALS(DonateToTreasury)
    {
        // NOTE: This procedure transfers QMINE from the invoker's *managed* balance (managed by this SC)
        // to the SC's internal treasury.
        // A one-time setup by the donor is required:
        // 1. Call QX::TransferShareManagementRights to give this SC management rights over the QMINE.
        // 2. Call this DonateToTreasury procedure to transfer ownership to the SC.

        // This procedure has no fee, refund any invocation reward
        if (qpi.invocationReward() > 0)
        {
            qpi.transfer(qpi.invocator(), qpi.invocationReward());
        }

        output.status = QRWA_STATUS_FAILURE_GENERAL;
        locals.logger.contractId = CONTRACT_INDEX;
        locals.logger.logType = QRWA_LOG_TYPE_TREASURY_DONATION;
        locals.logger.primaryId = qpi.invocator();
        locals.logger.valueA = input.amount;

        if (state.mQmineAsset.issuer == NULL_ID)
        {
            output.status = QRWA_STATUS_FAILURE_WRONG_STATE; // QMINE asset not set
            locals.logger.valueB = output.status;
            LOG_INFO(locals.logger);
            return;
        }
        if (input.amount == 0)
        {
            output.status = QRWA_STATUS_FAILURE_INVALID_INPUT;
            locals.logger.valueB = output.status;
            LOG_INFO(locals.logger);
            return;
        }

        // Check if user has granted management rights to this SC
        locals.balance = qpi.numberOfShares(state.mQmineAsset,
            { qpi.invocator(), SELF_INDEX },
            { qpi.invocator(), SELF_INDEX });

        if (locals.balance < static_cast<sint64>(input.amount))
        {
            output.status = QRWA_STATUS_FAILURE_INSUFFICIENT_BALANCE; // Not enough managed shares
            locals.logger.valueB = output.status;
            LOG_INFO(locals.logger);
            return;
        }

        // Transfer QMINE from invoker (managed by SELF) to SELF (owned by SELF)
        locals.transferResult = qpi.transferShareOwnershipAndPossession(
            state.mQmineAsset.assetName,
            state.mQmineAsset.issuer,
            qpi.invocator(), // current owner
            qpi.invocator(), // current possessor
            input.amount,
            SELF             // new owner and possessor
        );

        if (locals.transferResult >= 0) // Transfer successful
        {
            state.mTreasuryBalance = sadd(state.mTreasuryBalance, input.amount);
            output.status = QRWA_STATUS_SUCCESS;
        }
        else
        {
            output.status = QRWA_STATUS_FAILURE_TRANSFER_FAILED;
        }

        locals.logger.valueB = output.status;
        LOG_INFO(locals.logger);
    }

    // Governance: Param Voting
    struct VoteGovParams_input
    {
        QRWAGovParams proposal;
    };
    struct VoteGovParams_output
    {
        uint64 status;
    };
    struct VoteGovParams_locals
    {
        uint64 currentBalance;
        uint64 i;
        uint64 foundProposal;
        uint64 proposalIndex;
        QRWALogger logger;
        QRWAGovProposal poll;
        sint64 rawBalance;
        QRWAGovParams existing;
        uint64 status;
    };
    PUBLIC_PROCEDURE_WITH_LOCALS(VoteGovParams)
    {
        output.status = QRWA_STATUS_FAILURE_GENERAL;
        locals.logger.contractId = CONTRACT_INDEX;
        locals.logger.logType = QRWA_LOG_TYPE_GOV_VOTE;
        locals.logger.primaryId = qpi.invocator();

        // Get voter's current QMINE balance
        locals.rawBalance = qpi.numberOfShares(state.mQmineAsset, AssetOwnershipSelect::byOwner(qpi.invocator()), AssetPossessionSelect::byPossessor(qpi.invocator()));
        locals.currentBalance = (locals.rawBalance > 0) ? static_cast<uint64>(locals.rawBalance) : 0;

        if (locals.currentBalance <= 0)
        {
            output.status = QRWA_STATUS_FAILURE_NOT_AUTHORIZED;
            locals.logger.logType = QRWA_LOG_TYPE_ERROR;
            locals.logger.valueB = output.status;
            LOG_INFO(locals.logger);
            if (qpi.invocationReward() > 0)
            {
                qpi.transfer(qpi.invocator(), qpi.invocationReward());
            }
            return;
        }

        // Validate proposal percentages
        if (sadd(sadd(input.proposal.electricityPercent, input.proposal.maintenancePercent), input.proposal.reinvestmentPercent) > QRWA_PERCENT_DENOMINATOR)
        {
            output.status = QRWA_STATUS_FAILURE_INVALID_INPUT;
            locals.logger.logType = QRWA_LOG_TYPE_ERROR;
            locals.logger.valueB = output.status;
            LOG_INFO(locals.logger);
            if (qpi.invocationReward() > 0)
            {
                qpi.transfer(qpi.invocator(), qpi.invocationReward());
            }
            return;
        }
        if (input.proposal.mAdminAddress == NULL_ID)
        {
            output.status = QRWA_STATUS_FAILURE_INVALID_INPUT;
            locals.logger.logType = QRWA_LOG_TYPE_ERROR;
            locals.logger.valueB = output.status;
            LOG_INFO(locals.logger);
            if (qpi.invocationReward() > 0)
            {
                qpi.transfer(qpi.invocator(), qpi.invocationReward());
            }
            return;
        }

        // Now process the new/updated vote
        locals.foundProposal = 0;
        locals.proposalIndex = NULL_INDEX;

        // Check if the current proposal matches any existing unique proposal
        for (locals.i = 0; locals.i < QRWA_MAX_GOV_POLLS; locals.i++)
        {
            locals.existing = state.mGovPolls.get(locals.i).params;
            locals.status = state.mGovPolls.get(locals.i).status;

            if (locals.status == QRWA_POLL_STATUS_ACTIVE &&
                locals.existing.electricityAddress == input.proposal.electricityAddress &&
                locals.existing.maintenanceAddress == input.proposal.maintenanceAddress &&
                locals.existing.reinvestmentAddress == input.proposal.reinvestmentAddress &&
                locals.existing.qmineDevAddress == input.proposal.qmineDevAddress &&
                locals.existing.mAdminAddress == input.proposal.mAdminAddress &&
                locals.existing.electricityPercent == input.proposal.electricityPercent &&
                locals.existing.maintenancePercent == input.proposal.maintenancePercent &&
                locals.existing.reinvestmentPercent == input.proposal.reinvestmentPercent)
            {
                locals.foundProposal = 1;
                locals.proposalIndex = locals.i; // This is the proposal we are voting for
                break;
            }
        }

        // If proposal not found, create it in a new slot
        if (locals.foundProposal == 0)
        {
            if (state.mNewGovPollsThisEpoch >= QRWA_MAX_NEW_GOV_POLLS_PER_EPOCH)
            {
                output.status = QRWA_STATUS_FAILURE_LIMIT_REACHED;
                locals.logger.logType = QRWA_LOG_TYPE_ERROR;
                locals.logger.valueB = output.status;
                LOG_INFO(locals.logger);
                if (qpi.invocationReward() > 0)
                {
                    qpi.transfer(qpi.invocator(), qpi.invocationReward());
                }
                return;
            }

            locals.proposalIndex = mod(state.mCurrentGovProposalId, QRWA_MAX_GOV_POLLS);

            // Clear old data at this slot
            locals.poll = state.mGovPolls.get(locals.proposalIndex);
            locals.poll.proposalId = state.mCurrentGovProposalId;
            locals.poll.params = input.proposal;
            locals.poll.score = 0; // Will be count at END_EPOCH
            locals.poll.status = QRWA_POLL_STATUS_ACTIVE;

            state.mGovPolls.set(locals.proposalIndex, locals.poll);

            state.mCurrentGovProposalId++;
            state.mNewGovPollsThisEpoch++;
        }

        state.mShareholderVoteMap.set(qpi.invocator(), locals.proposalIndex);
        output.status = QRWA_STATUS_SUCCESS;

        locals.logger.valueA = locals.proposalIndex; // Log the index voted for/added
        locals.logger.valueB = output.status;
        LOG_INFO(locals.logger);
        if (qpi.invocationReward() > 0)
        {
            qpi.transfer(qpi.invocator(), qpi.invocationReward());
        }
    }




    // deposit general assets
    struct DepositGeneralAsset_input
    {
        Asset asset;
        uint64 amount;
    };
    struct DepositGeneralAsset_output
    {
        uint64 status;
    };
    struct DepositGeneralAsset_locals
    {
        sint64 transferResult;
        sint64 balance;
        uint64 currentAssetBalance;
        QRWALogger logger;
        QRWAAsset wrapper;
    };
    PUBLIC_PROCEDURE_WITH_LOCALS(DepositGeneralAsset)
    {
        // This procedure has no fee
        if (qpi.invocationReward() > 0)
        {
            qpi.transfer(qpi.invocator(), qpi.invocationReward());
        }

        output.status = QRWA_STATUS_FAILURE_GENERAL;
        locals.logger.contractId = CONTRACT_INDEX;
        locals.logger.logType = QRWA_LOG_TYPE_ADMIN_ACTION;
        locals.logger.primaryId = qpi.invocator();
        locals.logger.valueA = input.asset.assetName;

        if (qpi.invocator() != state.mCurrentGovParams.mAdminAddress)
        {
            output.status = QRWA_STATUS_FAILURE_NOT_AUTHORIZED;
            locals.logger.valueB = output.status;
            LOG_INFO(locals.logger);
            return;
        }

        if (input.amount == 0 || input.asset.issuer == NULL_ID)
        {
            output.status = QRWA_STATUS_FAILURE_INVALID_INPUT;
            locals.logger.valueB = output.status;
            LOG_INFO(locals.logger);
            return;
        }

        // Check if admin has granted management rights to this SC
        locals.balance = qpi.numberOfShares(input.asset,
            { qpi.invocator(), SELF_INDEX },
            { qpi.invocator(), SELF_INDEX });

        if (locals.balance < static_cast<sint64>(input.amount))
        {
            output.status = QRWA_STATUS_FAILURE_INSUFFICIENT_BALANCE; // Not enough managed shares
            locals.logger.valueB = output.status;
            LOG_INFO(locals.logger);
            return;
        }

        // Transfer asset from admin (managed by SELF) to SELF (owned by SELF)
        locals.transferResult = qpi.transferShareOwnershipAndPossession(
            input.asset.assetName,
            input.asset.issuer,
            qpi.invocator(), // current owner
            qpi.invocator(), // current possessor
            input.amount,
            SELF             // new owner and possessor
        );

        if (locals.transferResult >= 0) // Transfer successful
        {
            locals.wrapper.setFrom(input.asset);
            state.mGeneralAssetBalances.get(locals.wrapper, locals.currentAssetBalance); // 0 if not exist
            locals.currentAssetBalance = sadd(locals.currentAssetBalance, input.amount);
            state.mGeneralAssetBalances.set(locals.wrapper, locals.currentAssetBalance);
            output.status = QRWA_STATUS_SUCCESS;
        }
        else
        {
            output.status = QRWA_STATUS_FAILURE_TRANSFER_FAILED;
        }

        locals.logger.valueB = output.status;
        LOG_INFO(locals.logger);
    }

    struct RevokeAssetManagementRights_input
    {
        Asset asset;
        sint64 numberOfShares;
    };
    struct RevokeAssetManagementRights_output
    {
        sint64 transferredNumberOfShares;
        uint64 status;
    };
    struct RevokeAssetManagementRights_locals
    {
        QRWALogger logger;
        sint64 managedBalance;
        sint64 result;
    };
    PUBLIC_PROCEDURE_WITH_LOCALS(RevokeAssetManagementRights)
    {
        // This procedure allows a user to revoke asset management rights from qRWA
        // and transfer them back to QX, which is the default manager for trading
        // Ref: MSVAULT

        output.status = QRWA_STATUS_FAILURE_GENERAL;
        output.transferredNumberOfShares = 0;

        locals.logger.contractId = CONTRACT_INDEX;
        locals.logger.primaryId = qpi.invocator();
        locals.logger.valueA = input.asset.assetName;
        locals.logger.valueB = input.numberOfShares;

        if (qpi.invocationReward() < (sint64)QRWA_RELEASE_MANAGEMENT_FEE)
        {
            qpi.transfer(qpi.invocator(), qpi.invocationReward());
            output.transferredNumberOfShares = 0;
            output.status = QRWA_STATUS_FAILURE_INSUFFICIENT_FEE;
            locals.logger.logType = QRWA_LOG_TYPE_ERROR;
            locals.logger.valueB = output.status;
            LOG_INFO(locals.logger);
            return;
        }

        if (qpi.invocationReward() > (sint64)QRWA_RELEASE_MANAGEMENT_FEE)
        {
            qpi.transfer(qpi.invocator(), qpi.invocationReward() - (sint64)QRWA_RELEASE_MANAGEMENT_FEE);
        }

        // must transfer a positive number of shares.
        if (input.numberOfShares <= 0)
        {
            // Refund the fee if params are invalid
            qpi.transfer(qpi.invocator(), (sint64)QRWA_RELEASE_MANAGEMENT_FEE);
            output.transferredNumberOfShares = 0;
            output.status = QRWA_STATUS_FAILURE_INVALID_INPUT;
            locals.logger.logType = QRWA_LOG_TYPE_ERROR;
            locals.logger.valueB = output.status;
            LOG_INFO(locals.logger);
            return;
        }

        // Check if qRWA actually manages the specified number of shares for the caller.
        locals.managedBalance = qpi.numberOfShares(
            input.asset,
            { qpi.invocator(), SELF_INDEX },
            { qpi.invocator(), SELF_INDEX }
        );

        if (locals.managedBalance < input.numberOfShares)
        {
            // The user is trying to revoke more shares than are managed by qRWA.
            qpi.transfer(qpi.invocator(), (sint64)QRWA_RELEASE_MANAGEMENT_FEE);
            output.transferredNumberOfShares = 0;
            output.status = QRWA_STATUS_FAILURE_INSUFFICIENT_BALANCE;
            locals.logger.logType = QRWA_LOG_TYPE_ERROR;
            locals.logger.valueB = output.status;
            LOG_INFO(locals.logger);
        }
        else
        {
            // The balance check passed. Proceed to release the management rights to QX.
            locals.result = qpi.releaseShares(
                input.asset,
                qpi.invocator(), // owner
                qpi.invocator(), // possessor
                input.numberOfShares,
                QX_CONTRACT_INDEX,   // destination ownership managing contract
                QX_CONTRACT_INDEX,   // destination possession managing contract
                QRWA_RELEASE_MANAGEMENT_FEE // offered fee to QX
            );

            if (locals.result < 0)
            {
                // Transfer failed
                output.transferredNumberOfShares = 0;
                output.status = QRWA_STATUS_FAILURE_TRANSFER_FAILED;
                locals.logger.logType = QRWA_LOG_TYPE_ERROR;
            }
            else
            {
                // Success, the fee was spent.
                output.transferredNumberOfShares = input.numberOfShares;
                output.status = QRWA_STATUS_SUCCESS;
                locals.logger.logType = QRWA_LOG_TYPE_ADMIN_ACTION; // Or a more specific type

                // Since the invocation reward (100 QU) was added to mRevenuePoolB 
                // via POST_INCOMING_TRANSFER, but we just spent it in releaseShares,
                // we must remove it from the pool to keep the accountant in sync 
                // with the actual balance.
                if (state.mRevenuePoolB >= QRWA_RELEASE_MANAGEMENT_FEE)
                {
                    state.mRevenuePoolB -= QRWA_RELEASE_MANAGEMENT_FEE;
                }
            }
            locals.logger.valueB = output.status;
            LOG_INFO(locals.logger);
        }
    }

    // ── SetPoolARevenueAddress: Admin-only setter for mPoolARevenueAddress ──
    struct SetPoolARevenueAddress_input
    {
        id newAddress;
    };
    struct SetPoolARevenueAddress_output
    {
        uint64 status;
    };
    struct SetPoolARevenueAddress_locals
    {
        QRWALogger logger;
    };
    PUBLIC_PROCEDURE_WITH_LOCALS(SetPoolARevenueAddress)
    {
        output.status = QRWA_STATUS_FAILURE_GENERAL;
        locals.logger.contractId = CONTRACT_INDEX;
        locals.logger.logType = QRWA_LOG_TYPE_ADMIN_ACTION;
        locals.logger.primaryId = qpi.invocator();

        // Refund invocation reward
        if (qpi.invocationReward() > 0)
        {
            qpi.transfer(qpi.invocator(), qpi.invocationReward());
        }

        // Admin-only check
        if (qpi.invocator() != state.mCurrentGovParams.mAdminAddress)
        {
            output.status = QRWA_STATUS_FAILURE_NOT_AUTHORIZED;
            locals.logger.logType = QRWA_LOG_TYPE_ERROR;
            locals.logger.valueB = output.status;
            LOG_INFO(locals.logger);
            return;
        }

        // Validate new address is not NULL
        if (input.newAddress == NULL_ID)
        {
            output.status = QRWA_STATUS_FAILURE_INVALID_INPUT;
            locals.logger.logType = QRWA_LOG_TYPE_ERROR;
            locals.logger.valueB = output.status;
            LOG_INFO(locals.logger);
            return;
        }

        // Set the new Pool A revenue address
        state.mPoolARevenueAddress = input.newAddress;
        output.status = QRWA_STATUS_SUCCESS;
        locals.logger.valueA = 1; // signals address was set
        locals.logger.valueB = output.status;
        LOG_INFO(locals.logger);
    }

    /***************************************************/
    /***************** PUBLIC FUNCTIONS ****************/
    /***************************************************/

    // Governance: Param Voting
    struct GetGovParams_input {};
    struct GetGovParams_output
    {
        QRWAGovParams params;
    };
    PUBLIC_FUNCTION(GetGovParams)
    {
        output.params = state.mCurrentGovParams;
    }

    struct GetGovPoll_input
    {
        uint64 proposalId;
    };
    struct GetGovPoll_output
    {
        QRWAGovProposal proposal;
        uint64 status; // 0=NotFound, 1=Found
    };
    struct GetGovPoll_locals
    {
        uint64 pollIndex;
    };
    PUBLIC_FUNCTION_WITH_LOCALS(GetGovPoll)
    {
        output.status = QRWA_STATUS_FAILURE_NOT_FOUND;

        locals.pollIndex = mod(input.proposalId, QRWA_MAX_GOV_POLLS);
        output.proposal = state.mGovPolls.get(locals.pollIndex);

        if (output.proposal.proposalId == input.proposalId)
        {
            output.status = QRWA_STATUS_SUCCESS;
        }
        else
        {
            // Clear output if not the poll we're looking for
            setMemory(output.proposal, 0);
        }
    }



    // Balances & Info
    struct GetTreasuryBalance_input {};
    struct GetTreasuryBalance_output
    {
        uint64 balance;
    };
    PUBLIC_FUNCTION(GetTreasuryBalance)
    {
        output.balance = state.mTreasuryBalance;
    }

    struct GetDividendBalances_input {};
    struct GetDividendBalances_output
    {
        uint64 revenuePoolA;
        uint64 revenuePoolB;
        uint64 dedicatedRevenuePool;
        uint64 poolAQmineDividend;
        uint64 poolAQrwaDividend;
        uint64 poolBQmineDividend;
        uint64 poolBQrwaDividend;
        uint64 poolCQmineDividend;
        uint64 poolCQrwaDividend;
    };
    PUBLIC_FUNCTION(GetDividendBalances)
    {
        output.revenuePoolA = state.mRevenuePoolA;
        output.revenuePoolB = state.mRevenuePoolB;
        output.dedicatedRevenuePool = state.mDedicatedRevenuePool;
        output.poolAQmineDividend = state.mPoolAQmineDividend;
        output.poolAQrwaDividend = state.mPoolAQrwaDividend;
        output.poolBQmineDividend = state.mPoolBQmineDividend;
        output.poolBQrwaDividend = state.mPoolBQrwaDividend;
        output.poolCQmineDividend = state.mPoolCQmineDividend;
        output.poolCQrwaDividend = state.mPoolCQrwaDividend;
    }

    struct GetTotalDistributed_input {};
    struct GetTotalDistributed_output
    {
        uint64 totalPoolADistributed;
        uint64 totalPoolBDistributed;
        uint64 totalPoolCDistributed;
        uint64 payoutTotalQmineBegin;
    };
    PUBLIC_FUNCTION(GetTotalDistributed)
    {
        output.totalPoolADistributed = state.mTotalPoolADistributed;
        output.totalPoolBDistributed = state.mTotalPoolBDistributed;
        output.totalPoolCDistributed = state.mTotalPoolCDistributed;
        output.payoutTotalQmineBegin = state.mPayoutTotalQmineBegin;
    }

    // Diagnostic: Query configured contract addresses
    struct GetContractAddresses_input {};
    struct GetContractAddresses_output
    {
        id dedicatedRevenueAddress;
        id poolARevenueAddress;
        id fundraisingAddress;
    };
    PUBLIC_FUNCTION(GetContractAddresses)
    {
        output.dedicatedRevenueAddress = state.mDedicatedRevenueAddress;
        output.poolARevenueAddress = state.mPoolARevenueAddress;
        output.fundraisingAddress = state.mFundraisingAddress;
    }



    struct GetActiveGovPollIds_input {};
    struct GetActiveGovPollIds_output
    {
        uint64 count;
        Array<uint64, QRWA_MAX_GOV_POLLS> ids;
    };
    struct GetActiveGovPollIds_locals
    {
        uint64 i;
    };
    PUBLIC_FUNCTION_WITH_LOCALS(GetActiveGovPollIds)
    {
        output.count = 0;
        for (locals.i = 0; locals.i < QRWA_MAX_GOV_POLLS; locals.i++)
        {
            if (state.mGovPolls.get(locals.i).status == QRWA_POLL_STATUS_ACTIVE)
            {
                output.ids.set(output.count, state.mGovPolls.get(locals.i).proposalId);
                output.count++;
            }
        }
    }

    struct GetGeneralAssetBalance_input
    {
        Asset asset;
    };
    struct GetGeneralAssetBalance_output
    {
        uint64 balance;
        uint64 status;
    };
    struct GetGeneralAssetBalance_locals
    {
        uint64 balance;
        QRWAAsset wrapper;
    };
    PUBLIC_FUNCTION_WITH_LOCALS(GetGeneralAssetBalance) {
        locals.balance = 0;
        locals.wrapper.setFrom(input.asset);
        if (state.mGeneralAssetBalances.get(locals.wrapper, locals.balance)) {
            output.balance = locals.balance;
            output.status = 1;
        }
        else {
            output.balance = 0;
            output.status = 0;
        }
    }

    struct GetGeneralAssets_input {};
    struct GetGeneralAssets_output
    {
        uint64 count;
        Array<Asset, QRWA_MAX_ASSETS> assets;
        Array<uint64, QRWA_MAX_ASSETS> balances;
    };
    struct GetGeneralAssets_locals
    {
        sint64 iterIndex;
        QRWAAsset currentAsset;
        uint64 currentBalance;
    };
    PUBLIC_FUNCTION_WITH_LOCALS(GetGeneralAssets)
    {
        output.count = 0;
        locals.iterIndex = NULL_INDEX;

        while (true)
        {
            locals.iterIndex = state.mGeneralAssetBalances.nextElementIndex(locals.iterIndex);

            if (locals.iterIndex == NULL_INDEX)
            {
                break;
            }

            locals.currentAsset = state.mGeneralAssetBalances.key(locals.iterIndex);
            locals.currentBalance = state.mGeneralAssetBalances.value(locals.iterIndex);

            // Only return "active" assets (balance > 0)
            if (locals.currentBalance > 0)
            {
                output.assets.set(output.count, locals.currentAsset);
                output.balances.set(output.count, locals.currentBalance);
                output.count++;

                if (output.count >= QRWA_MAX_ASSETS)
                {
                    break;
                }
            }
        }
    }

    // GetScDividendTracking (fn 15): Lists all SC contract IDs from which dividends were received
    // and their cumulative totals. All SC dividends are routed to Pool B.
    struct GetScDividendTracking_input {};
    struct GetScDividendTracking_output
    {
        uint64 count;
        Array<id, QRWA_MAX_ASSETS> scContractIds;
        Array<uint64, QRWA_MAX_ASSETS> cumulativeDividends;
    };
    struct GetScDividendTracking_locals
    {
        sint64 iterIndex;
    };
    PUBLIC_FUNCTION_WITH_LOCALS(GetScDividendTracking)
    {
        output.count = 0;
        locals.iterIndex = NULL_INDEX;

        while (true)
        {
            locals.iterIndex = state.mScDividendTracker.nextElementIndex(locals.iterIndex);
            if (locals.iterIndex == NULL_INDEX)
            {
                break;
            }

            output.scContractIds.set(output.count, state.mScDividendTracker.key(locals.iterIndex));
            output.cumulativeDividends.set(output.count, state.mScDividendTracker.value(locals.iterIndex));
            output.count++;

            if (output.count >= QRWA_MAX_ASSETS)
            {
                break;
            }
        }
    }

    // Per-pool payout ring buffer queries (paginated).
    // Ring buffer stores QRWA_PAYOUT_RING_SIZE entries, query returns max QRWA_PAYOUT_PAGE_SIZE per call.
    // Entries are returned newest-first. page=0 → most recent, page=1 → next 1000, etc.
    static constexpr uint64 QRWA_PAYOUT_PAGE_SIZE = 512;

    // GetPayoutsPoolA (fn 11): Pool A payouts — QMINE + qRWA holders (types 0+1+2, after gov fees)
    struct GetPayoutsQmine_input
    {
        uint16 page; // 0 = newest entries
    };
    struct GetPayoutsQmine_output
    {
        Array<QRWAPayoutEntry, QRWA_PAYOUT_PAGE_SIZE> payouts;
        uint16 nextIdx;        // Write cursor in full ring buffer
        uint16 returnedCount;  // Number of valid entries in this page
        uint16 page;           // Echoed page number
        uint16 totalPages;     // Total available pages
    };
    struct GetPayoutsQmine_locals
    {
        uint64 i;
        uint64 ringIdx;
        uint64 count;
        uint64 startOffset;
    };
    PUBLIC_FUNCTION_WITH_LOCALS(GetPayoutsQmine)
    {
        output.nextIdx = state.mPayoutsPoolANextIdx;
        output.page = input.page;
        output.totalPages = (uint16)(div<uint64>(QRWA_PAYOUT_RING_SIZE + QRWA_PAYOUT_PAGE_SIZE - 1, QRWA_PAYOUT_PAGE_SIZE));
        locals.startOffset = (uint64)input.page * QRWA_PAYOUT_PAGE_SIZE;
        locals.count = 0;
        for (locals.i = 0; locals.i < QRWA_PAYOUT_PAGE_SIZE && (locals.startOffset + locals.i) < QRWA_PAYOUT_RING_SIZE; locals.i++)
        {
            locals.ringIdx = ((uint64)state.mPayoutsPoolANextIdx - 1 - locals.startOffset - locals.i + QRWA_PAYOUT_RING_SIZE) & (QRWA_PAYOUT_RING_SIZE - 1);
            output.payouts.set(locals.count, state.mPayoutsPoolA.get(locals.ringIdx));
            locals.count++;
        }
        output.returnedCount = (uint16)locals.count;
    }

    // GetPayoutsPoolB (fn 13): Pool B payouts — QMINE + qRWA holders (types 0+1+2, no gov fees)
    struct GetPayoutsQrwa_input
    {
        uint16 page;
    };
    struct GetPayoutsQrwa_output
    {
        Array<QRWAPayoutEntry, QRWA_PAYOUT_PAGE_SIZE> payouts;
        uint16 nextIdx;
        uint16 returnedCount;
        uint16 page;
        uint16 totalPages;
    };
    struct GetPayoutsQrwa_locals
    {
        uint64 i;
        uint64 ringIdx;
        uint64 count;
        uint64 startOffset;
    };
    PUBLIC_FUNCTION_WITH_LOCALS(GetPayoutsQrwa)
    {
        output.nextIdx = state.mPayoutsPoolBNextIdx;
        output.page = input.page;
        output.totalPages = (uint16)(div<uint64>(QRWA_PAYOUT_RING_SIZE + QRWA_PAYOUT_PAGE_SIZE - 1, QRWA_PAYOUT_PAGE_SIZE));
        locals.startOffset = (uint64)input.page * QRWA_PAYOUT_PAGE_SIZE;
        locals.count = 0;
        for (locals.i = 0; locals.i < QRWA_PAYOUT_PAGE_SIZE && (locals.startOffset + locals.i) < QRWA_PAYOUT_RING_SIZE; locals.i++)
        {
            locals.ringIdx = ((uint64)state.mPayoutsPoolBNextIdx - 1 - locals.startOffset - locals.i + QRWA_PAYOUT_RING_SIZE) & (QRWA_PAYOUT_RING_SIZE - 1);
            output.payouts.set(locals.count, state.mPayoutsPoolB.get(locals.ringIdx));
            locals.count++;
        }
        output.returnedCount = (uint16)locals.count;
    }

    // GetPayoutsPoolC (fn 14): Pool C payouts — QMINE + dedicated qRWA holders (types 0+1+3)
    struct GetPayoutsDedicated_input
    {
        uint16 page;
    };
    struct GetPayoutsDedicated_output
    {
        Array<QRWAPayoutEntry, QRWA_PAYOUT_PAGE_SIZE> payouts;
        uint16 nextIdx;
        uint16 returnedCount;
        uint16 page;
        uint16 totalPages;
    };
    struct GetPayoutsDedicated_locals
    {
        uint64 i;
        uint64 ringIdx;
        uint64 count;
        uint64 startOffset;
    };
    PUBLIC_FUNCTION_WITH_LOCALS(GetPayoutsDedicated)
    {
        output.nextIdx = state.mPayoutsPoolCNextIdx;
        output.page = input.page;
        output.totalPages = (uint16)(div<uint64>(QRWA_PAYOUT_RING_SIZE + QRWA_PAYOUT_PAGE_SIZE - 1, QRWA_PAYOUT_PAGE_SIZE));
        locals.startOffset = (uint64)input.page * QRWA_PAYOUT_PAGE_SIZE;
        locals.count = 0;
        for (locals.i = 0; locals.i < QRWA_PAYOUT_PAGE_SIZE && (locals.startOffset + locals.i) < QRWA_PAYOUT_RING_SIZE; locals.i++)
        {
            locals.ringIdx = ((uint64)state.mPayoutsPoolCNextIdx - 1 - locals.startOffset - locals.i + QRWA_PAYOUT_RING_SIZE) & (QRWA_PAYOUT_RING_SIZE - 1);
            output.payouts.set(locals.count, state.mPayoutsPoolC.get(locals.ringIdx));
            locals.count++;
        }
        output.returnedCount = (uint16)locals.count;
    }



    /***************************************************/
    /***************** SYSTEM PROCEDURES ***************/
    /***************************************************/


    INITIALIZE()
    {
        // QMINE Asset Constant
        // Issuer: QMINEQQXYBEGBHNSUPOUYDIQKZPCBPQIIHUUZMCPLBPCCAIARVZBTYKGFCWM
        // Name: 297666170193 ("QMINE")
        state.mQmineAsset.assetName = 297666170193ULL;
        state.mQmineAsset.issuer = ID(
            _Q, _M, _I, _N, _E, _Q, _Q, _X, _Y, _B, _E, _G, _B, _H, _N, _S,
            _U, _P, _O, _U, _Y, _D, _I, _Q, _K, _Z, _P, _C, _B, _P, _Q, _I,
            _I, _H, _U, _U, _Z, _M, _C, _P, _L, _B, _P, _C, _C, _A, _I, _A,
            _R, _V, _Z, _B, _T, _Y, _K, _G
        );
        state.mTreasuryBalance = 0;
        setMemory(state.mLastPayoutTime, 0);
        state.mLastPayoutTick = 0;

        // Initialize default governance parameters
        state.mCurrentGovParams.mAdminAddress = ID(
            _S, _T, _T, _I, _M, _W, _J, _N, _W, _X, _A, _R, _P, _B, _P, _B,
            _H, _B, _A, _R, _P, _M, _C, _W, _V, _T, _E, _C, _D, _H, _L, _T,
            _I, _D, _F, _B, _X, _R, _D, _W, _D, _B, _U, _A, _W, _Z, _Z, _W,
            _E, _P, _J, _E, _J, _Y, _Z, _A
        );
        state.mCurrentGovParams.electricityAddress = ID(
            _J, _T, _I, _D, _B, _A, _Q, _S, _M, _H, _F, _S, _F, _D, _P, _C,
            _M, _Q, _G, _B, _Z, _V, _R, _N, _N, _T, _K, _A, _J, _N, _Z, _G,
            _E, _O, _L, _Y, _O, _U, _F, _N, _U, _E, _S, _M, _Q, _L, _N, _G,
            _W, _J, _B, _A, _R, _G, _Q, _B
        );
        state.mCurrentGovParams.maintenanceAddress = ID(
            _J, _N, _R, _Z, _M, _D, _C, _B, _Q, _Y, _F, _C, _F, _A, _T, _G,
            _L, _O, _Z, _V, _E, _W, _K, _F, _W, _E, _P, _D, _H, _S, _I, _G,
            _R, _F, _O, _F, _C, _G, _P, _J, _F, _E, _Z, _Q, _Y, _Q, _Z, _P,
            _B, _K, _M, _S, _S, _V, _J, _B
        );
        state.mCurrentGovParams.reinvestmentAddress = ID(
            _C, _Q, _V, _D, _N, _N, _G, _N, _I, _R, _L, _T, _B, _G, _D, _J,
            _F, _P, _W, _U, _J, _A, _Y, _O, _D, _J, _E, _C, _L, _N, _W, _W,
            _U, _T, _V, _U, _N, _W, _T, _A, _M, _D, _S, _Y, _F, _B, _N, _K,
            _S, _N, _D, _C, _A, _Y, _U, _D
        );

        // QMINE DEV's Address for receiving rewards from moved QMINE tokens
        // ZOXXIDCZIMGCECCFAXDDCMBBXCDAQJIHGOOATAFPSBFIOFOYECFKUFPBEMWC
        state.mCurrentGovParams.qmineDevAddress = ID(
            _R, _U, _J, _G, _S, _W, _E, _E, _E, _U, _C, _O, _O, _C, _D, _P,
            _A, _M, _U, _U, _Z, _S, _H, _I, _R, _Y, _N, _D, _A, _F, _D, _O,
            _W, _X, _F, _W, _A, _Q, _L, _Z, _R, _B, _N, _X, _G, _E, _X, _Q,
            _W, _B, _D, _C, _V, _U, _Z, _G
        );
        state.mCurrentGovParams.electricityPercent = 350;
        state.mCurrentGovParams.maintenancePercent = 50;
        state.mCurrentGovParams.reinvestmentPercent = 100;

        state.mCurrentGovProposalId = 0;
        state.mNewGovPollsThisEpoch = 0;

        // Initialize revenue pools
        state.mRevenuePoolA = 0;
        state.mRevenuePoolB = 0;
        state.mDedicatedRevenuePool = 0;
        state.mPoolAQmineDividend = 0;
        state.mPoolAQrwaDividend = 0;
        state.mPoolBQmineDividend = 0;
        state.mPoolBQrwaDividend = 0;
        state.mPoolCQmineDividend = 0;
        state.mPoolCQrwaDividend = 0;

        // Dedicated BTC revenue address (Pool C)
        // Production: USALFUZBICLZIEMYPSKLYDZJZRFBKYEONUGSWFXOIGRMWSJHLIPMEGZCVCMG
        // Testnet: WFCELJRTMTYEGHNTYONQOWVQIUYBVBPTSIRCOTJUXFIQAQPEYJQGQQSAVDDM
        state.mDedicatedRevenueAddress = ID(
            _W, _F, _C, _E, _L, _J, _R, _T, _M, _T, _Y, _E, _G, _H, _N, _T,
            _Y, _O, _N, _Q, _O, _W, _V, _Q, _I, _U, _Y, _B, _V, _B, _P, _T,
            _S, _I, _R, _C, _O, _T, _J, _U, _X, _F, _I, _Q, _A, _Q, _P, _E,
            _Y, _J, _Q, _G, _Q, _Q, _S, _A
        );

        // Fundraising address — excluded from ALL distributions
        // QTDSQGIEAPPMMDDSEHBHHETEUZHBUZXRYFKKTICWAAUXVEWNPCTGCAFBYWWB
        state.mFundraisingAddress = ID(
            _Q, _T, _D, _S, _Q, _G, _I, _E, _A, _P, _P, _M, _M, _D, _D, _S,
            _E, _H, _B, _H, _H, _E, _T, _E, _U, _Z, _H, _B, _U, _Z, _X, _R,
            _Y, _F, _K, _K, _T, _I, _C, _W, _A, _A, _U, _X, _V, _E, _W, _N,
            _P, _C, _T, _G, _C, _A, _F, _B
        );

        // Pool A revenue address (Mining / QMINE issuer)
        // Production: QMINEQQXYBEGBHNSUPOUYDIQKZPCBPQIIHUUZMCPLBPCCAIARVZBTYKGFCWM
        // Testnet: IZNUAVRCTNYBQBSFYWBBPQUXASPCYDZYKFFULCEGLCFCEQPTLDTKZQMENKRN
        state.mPoolARevenueAddress = ID(
            _I, _Z, _N, _U, _A, _V, _R, _C, _T, _N, _Y, _B, _Q, _B, _S, _F,
            _Y, _W, _B, _B, _P, _Q, _U, _X, _A, _S, _P, _C, _Y, _D, _Z, _Y,
            _K, _F, _F, _U, _L, _C, _E, _G, _L, _C, _F, _C, _E, _Q, _P, _T,
            _L, _D, _T, _K, _Z, _Q, _M, _E
        );

        // Initialize total distributed
        state.mTotalPoolADistributed = 0;
        state.mTotalPoolBDistributed = 0;
        state.mTotalPoolCDistributed = 0;

        // Initialize maps/arrays
        state.mBeginEpochBalances.reset();
        state.mEndEpochBalances.reset();
        state.mPayoutBeginBalances.reset();
        state.mPayoutEndBalances.reset();
        state.mGeneralAssetBalances.reset();
        state.mScDividendTracker.reset();
        state.mShareholderVoteMap.reset();

        setMemory(state.mGovPolls, 0);
    }

    struct BEGIN_EPOCH_locals
    {
        AssetPossessionIterator iter;
        uint64 balance;
        QRWALogger logger;
        id holder;
        uint64 existingBalance;
        id newDedicatedAddr;
    };
    BEGIN_EPOCH_WITH_LOCALS()
    {
        // ── One-time migrations (remove after epoch 202) ──
        if (qpi.epoch() <= 202)
        {
            // auto-initialize mPoolARevenueAddress if not set
            if (state.mPoolARevenueAddress == NULL_ID)
            {
                // Testnet: IZNUAVRCTNYBQBSFYWBBPQUXASPCYDZYKFFULCEGLCFCEQPTLDTKZQMENKRN
                // Production: change to QMINEQQXYBEGBHNSUPOUYDIQKZPCBPQIIHUUZMCPLBPCCAIARVZBTYKGFCWM
                state.mPoolARevenueAddress = ID(
                    _I, _Z, _N, _U, _A, _V, _R, _C, _T, _N, _Y, _B, _Q, _B, _S, _F,
                    _Y, _W, _B, _B, _P, _Q, _U, _X, _A, _S, _P, _C, _Y, _D, _Z, _Y,
                    _K, _F, _F, _U, _L, _C, _E, _G, _L, _C, _F, _C, _E, _Q, _P, _T,
                    _L, _D, _T, _K, _Z, _Q, _M, _E
                );
            }

            // auto-initialize mFundraisingAddress if not set
            if (state.mFundraisingAddress == NULL_ID)
            {
                state.mFundraisingAddress = ID(
                    _Q, _T, _D, _S, _Q, _G, _I, _E, _A, _P, _P, _M, _M, _D, _D, _S,
                    _E, _H, _B, _H, _H, _E, _T, _E, _U, _Z, _H, _B, _U, _Z, _X, _R,
                    _Y, _F, _K, _K, _T, _I, _C, _W, _A, _A, _U, _X, _V, _E, _W, _N,
                    _P, _C, _T, _G, _C, _A, _F, _B
                );
            }

            // update mDedicatedRevenueAddress to new Pool C address
            // Testnet: WFCELJRTMTYEGHNTYONQOWVQIUYBVBPTSIRCOTJUXFIQAQPEYJQGQQSAVDDM
            locals.newDedicatedAddr = ID(
                _W, _F, _C, _E, _L, _J, _R, _T, _M, _T, _Y, _E, _G, _H, _N, _T,
                _Y, _O, _N, _Q, _O, _W, _V, _Q, _I, _U, _Y, _B, _V, _B, _P, _T,
                _S, _I, _R, _C, _O, _T, _J, _U, _X, _F, _I, _Q, _A, _Q, _P, _E,
                _Y, _J, _Q, _G, _Q, _Q, _S, _A
            );
            if (state.mDedicatedRevenueAddress != locals.newDedicatedAddr)
            {
                state.mDedicatedRevenueAddress = locals.newDedicatedAddr;
            }
        }

        // Reset new poll counters
        state.mNewGovPollsThisEpoch = 0;

        state.mEndEpochBalances.reset();

        // Take snapshot of begin balances for QMINE holders
        state.mBeginEpochBalances.reset();
        state.mTotalQmineBeginEpoch = 0;

        if (state.mQmineAsset.issuer != NULL_ID)
        {
            for (locals.iter.begin(state.mQmineAsset); !locals.iter.reachedEnd(); locals.iter.next())
            {
                // Exclude SELF (Treasury) from dividend snapshot
                if (locals.iter.possessor() == SELF)
                {
                    continue;
                }
                // Exclude fundraising address from all distributions
                if (state.mFundraisingAddress != NULL_ID && locals.iter.possessor() == state.mFundraisingAddress)
                {
                    continue;
                }
                locals.balance = locals.iter.numberOfPossessedShares();
                locals.holder = locals.iter.possessor();

                if (locals.balance > 0)
                {
                    // Check if holder already exists in the map (e.g. from a different manager)
                    // If so, add to existing balance.
                    locals.existingBalance = 0;
                    state.mBeginEpochBalances.get(locals.holder, locals.existingBalance);

                    locals.balance = sadd(locals.existingBalance, locals.balance);

                    if (state.mBeginEpochBalances.set(locals.holder, locals.balance) != NULL_INDEX)
                    {
                        state.mTotalQmineBeginEpoch = sadd(state.mTotalQmineBeginEpoch, (uint64)locals.iter.numberOfPossessedShares());
                    }
                    else
                    {
                        // Log error - Max holders reached for snapshot
                        locals.logger.contractId = CONTRACT_INDEX;
                        locals.logger.logType = QRWA_LOG_TYPE_ERROR;
                        locals.logger.primaryId = locals.holder;
                        locals.logger.valueA = 11; // Error code: Begin Epoch Snapshot full
                        locals.logger.valueB = state.mBeginEpochBalances.population();
                        LOG_INFO(locals.logger);
                    }
                }
            }
        }
    }

    struct END_EPOCH_locals
    {
        AssetPossessionIterator iter;
        uint64 balance;

        sint64 iterIndex;
        id iterVoter;
        uint64 beginBalance;
        uint64 endBalance;
        uint64 votingPower;
        uint64 proposalIndex;
        uint64 currentScore;

        // Gov Params Voting
        uint64 i;
        uint64 topScore;
        uint64 topProposalIndex;
        uint64 totalQminePower;
        Array<uint64, QRWA_MAX_GOV_POLLS> govPollScores;
        uint64 govPassed;
        uint64 quorumThreshold;

        QRWALogger logger;
        uint64 epoch;

        sint64 copyIndex;
        id copyHolder;
        uint64 copyBalance;

        QRWAGovProposal govPoll;

        id holder;
        uint64 existingBalance;
    };
    END_EPOCH_WITH_LOCALS()
    {
        locals.epoch = qpi.epoch(); // Get current epoch for history records

        // Take snapshot of end balances for QMINE holders
        if (state.mQmineAsset.issuer != NULL_ID)
        {
            for (locals.iter.begin(state.mQmineAsset); !locals.iter.reachedEnd(); locals.iter.next())
            {
                // Exclude SELF (Treasury) from dividend snapshot
                if (locals.iter.possessor() == SELF)
                {
                    continue;
                }
                // Exclude fundraising address from all distributions
                if (state.mFundraisingAddress != NULL_ID && locals.iter.possessor() == state.mFundraisingAddress)
                {
                    continue;
                }
                locals.balance = locals.iter.numberOfPossessedShares();
                locals.holder = locals.iter.possessor();

                if (locals.balance > 0)
                {
                    // Check if holder already exists (multiple SC management)
                    locals.existingBalance = 0;
                    state.mEndEpochBalances.get(locals.holder, locals.existingBalance);

                    locals.balance = sadd(locals.existingBalance, locals.balance);

                    if (state.mEndEpochBalances.set(locals.holder, locals.balance) == NULL_INDEX)
                    {
                        // Log error - Max holders reached for snapshot
                        locals.logger.contractId = CONTRACT_INDEX;
                        locals.logger.logType = QRWA_LOG_TYPE_ERROR;
                        locals.logger.primaryId = locals.holder;
                        locals.logger.valueA = 12; // Error code: End Epoch Snapshot full
                        locals.logger.valueB = state.mEndEpochBalances.population();
                        LOG_INFO(locals.logger);
                    }
                }
            }
        }

        // Process Governance Parameter Voting (voted by QMINE holders)
        // Recount all votes from scratch using snapshots

        locals.totalQminePower = state.mTotalQmineBeginEpoch;
        locals.govPollScores.setAll(0); // Reset scores to zero.

        locals.iterIndex = NULL_INDEX; // Iterate all voters
        while (true)
        {
            locals.iterIndex = state.mShareholderVoteMap.nextElementIndex(locals.iterIndex);
            if (locals.iterIndex == NULL_INDEX)
            {
                break;
            }

            locals.iterVoter = state.mShareholderVoteMap.key(locals.iterIndex);

            // Get true voting power from snapshots
            locals.beginBalance = 0;
            locals.endBalance = 0;
            state.mBeginEpochBalances.get(locals.iterVoter, locals.beginBalance);
            state.mEndEpochBalances.get(locals.iterVoter, locals.endBalance);

            locals.votingPower = (locals.beginBalance < locals.endBalance) ? locals.beginBalance : locals.endBalance; // min(begin, end)

            if (locals.votingPower > 0) // Apply voting power
            {
                state.mShareholderVoteMap.get(locals.iterVoter, locals.proposalIndex);
                if (locals.proposalIndex < QRWA_MAX_GOV_POLLS)
                {
                    if (state.mGovPolls.get(locals.proposalIndex).status == QRWA_POLL_STATUS_ACTIVE)
                    {
                        locals.currentScore = locals.govPollScores.get(locals.proposalIndex);
                        locals.govPollScores.set(locals.proposalIndex, sadd(locals.currentScore, locals.votingPower));
                    }
                }
            }
        }

        // Find the winning proposal (max votes)
        locals.topScore = 0;
        locals.topProposalIndex = NULL_INDEX;

        for (locals.i = 0; locals.i < QRWA_MAX_GOV_POLLS; locals.i++)
        {
            if (state.mGovPolls.get(locals.i).status == QRWA_POLL_STATUS_ACTIVE)
            {
                locals.currentScore = locals.govPollScores.get(locals.i);
                if (locals.currentScore > locals.topScore)
                {
                    locals.topScore = locals.currentScore;
                    locals.topProposalIndex = locals.i;
                }
            }
        }

        // Calculate simple majority threshold (>50% of total voting power)
        locals.quorumThreshold = 0;
        if (locals.totalQminePower > 0)
        {
            locals.quorumThreshold = sadd(div<uint64>(locals.totalQminePower, 2ULL), 1ULL);
        }

        // Finalize Gov Vote (check against simple majority threshold)
        locals.govPassed = 0;
        if (locals.topScore >= locals.quorumThreshold && locals.topProposalIndex != NULL_INDEX)
        {
            // Proposal passes
            locals.govPassed = 1;
            state.mCurrentGovParams = state.mGovPolls.get(locals.topProposalIndex).params;

            locals.logger.contractId = CONTRACT_INDEX;
            locals.logger.logType = QRWA_LOG_TYPE_GOV_VOTE;
            locals.logger.primaryId = NULL_ID; // System event
            locals.logger.valueA = state.mGovPolls.get(locals.topProposalIndex).proposalId;
            locals.logger.valueB = QRWA_STATUS_SUCCESS; // Indicate params updated
            LOG_INFO(locals.logger);
        }

        // Update status for all active gov polls (for history)
        for (locals.i = 0; locals.i < QRWA_MAX_GOV_POLLS; locals.i++)
        {
            locals.govPoll = state.mGovPolls.get(locals.i);
            if (locals.govPoll.status == QRWA_POLL_STATUS_ACTIVE)
            {
                locals.govPoll.score = locals.govPollScores.get(locals.i);
                if (locals.govPassed == 1 && locals.i == locals.topProposalIndex)
                {
                    locals.govPoll.status = QRWA_POLL_STATUS_PASSED_EXECUTED;
                }
                else
                {
                    locals.govPoll.status = QRWA_POLL_STATUS_FAILED_VOTE;
                }
                state.mGovPolls.set(locals.i, locals.govPoll);
            }
        }

        // Reset governance voter map for the next epoch
        state.mShareholderVoteMap.reset();

        // Copy the finalized epoch snapshots to the payout buffers
        state.mPayoutBeginBalances.reset();
        state.mPayoutEndBalances.reset();
        state.mPayoutTotalQmineBegin = state.mTotalQmineBeginEpoch;

        // Copy mBeginEpochBalances -> mPayoutBeginBalances
        locals.copyIndex = NULL_INDEX;
        while (true)
        {
            locals.copyIndex = state.mBeginEpochBalances.nextElementIndex(locals.copyIndex);
            if (locals.copyIndex == NULL_INDEX)
            {
                break;
            }
            locals.copyHolder = state.mBeginEpochBalances.key(locals.copyIndex);
            locals.copyBalance = state.mBeginEpochBalances.value(locals.copyIndex);
            state.mPayoutBeginBalances.set(locals.copyHolder, locals.copyBalance);
        }

        // Copy mEndEpochBalances -> mPayoutEndBalances
        locals.copyIndex = NULL_INDEX;
        while (true)
        {
            locals.copyIndex = state.mEndEpochBalances.nextElementIndex(locals.copyIndex);
            if (locals.copyIndex == NULL_INDEX)
            {
                break;
            }
            locals.copyHolder = state.mEndEpochBalances.key(locals.copyIndex);
            locals.copyBalance = state.mEndEpochBalances.value(locals.copyIndex);
            state.mPayoutEndBalances.set(locals.copyHolder, locals.copyBalance);
        }
    }


    struct END_TICK_locals
    {
        DateAndTime now;
        uint64 durationMicros;
        uint64 msSinceLastPayout;

        // Gov fee locals
        uint64 totalGovPercent;
        uint64 totalFeeAmount;
        uint64 electricityPayout;
        uint64 maintenancePayout;
        uint64 reinvestmentPayout;

        // Per-pool revenue splitting
        uint64 qminePortion;
        uint64 qrwaPortion;

        // qRWA distribution (Pool A + B)
        uint64 eligibleShares;
        uint64 poolAAmountPerShare;
        uint64 poolBAmountPerShare;
        uint64 poolAQrwaDistributed;
        uint64 poolBQrwaDistributed;

        // Dedicated qRWA distribution (Pool C)
        uint64 dedicatedEligibleShares;
        uint64 dedicatedAmountPerShare;
        uint64 dedicatedDistributed;
        uint64 qrwaShares;
        uint64 requiredQmine;
        sint64 qmineBalance;

        // QMINE distribution
        sint64 qminePayoutIndex;
        id holder;
        uint64 beginBalance;
        uint64 endBalance;
        uint64 eligibleBalance;
        uint128 scaledPayout_128;
        uint128 eligiblePayout_128;
        uint128 poolAQmine_128;
        uint128 poolBQmine_128;
        uint128 poolCQmine_128;
        uint64 payout_u64;
        uint64 foundEnd;

        QRWALogger logger;
        QRWAPayoutEntry payoutEntry;
        AssetPossessionIterator qrwaIter;
        Asset qrwaAsset;


    };
    END_TICK_WITH_LOCALS()
    {
        locals.now = qpi.now();

        // TESTING: Check every 100 ticks for payout distribution
        // Production: Use day/hour check instead (QRWA_PAYOUT_DAY + QRWA_PAYOUT_HOUR)
        if (state.mLastPayoutTick == 0 || (qpi.tick() - state.mLastPayoutTick) >= QRWA_PAYOUT_TICK_INTERVAL)
        {
                locals.logger.contractId = CONTRACT_INDEX;
                locals.logger.logType = QRWA_LOG_TYPE_DISTRIBUTION;

                // Calculate and pay out governance fees from Pool A (mined funds)
                // gov_percentage = electricity_percent + maintenance_percent + reinvestment_percent
                locals.totalGovPercent = sadd(sadd(state.mCurrentGovParams.electricityPercent, state.mCurrentGovParams.maintenancePercent), state.mCurrentGovParams.reinvestmentPercent);
                locals.totalFeeAmount = 0;

                if (locals.totalGovPercent > 0 && locals.totalGovPercent <= QRWA_PERCENT_DENOMINATOR && state.mRevenuePoolA > 0)
                {
                    locals.electricityPayout = div<uint64>(smul(state.mRevenuePoolA, state.mCurrentGovParams.electricityPercent), QRWA_PERCENT_DENOMINATOR);
                    if (locals.electricityPayout > 0 && state.mCurrentGovParams.electricityAddress != NULL_ID)
                    {
                        if (qpi.transfer(state.mCurrentGovParams.electricityAddress, locals.electricityPayout) >= 0)
                        {
                            locals.totalFeeAmount = sadd(locals.totalFeeAmount, locals.electricityPayout);
                        }
                        else
                        {
                            locals.logger.logType = QRWA_LOG_TYPE_ERROR;
                            locals.logger.primaryId = state.mCurrentGovParams.electricityAddress;
                            locals.logger.valueA = locals.electricityPayout;
                            locals.logger.valueB = QRWA_STATUS_FAILURE_TRANSFER_FAILED;
                            LOG_INFO(locals.logger);
                        }
                    }

                    locals.maintenancePayout = div<uint64>(smul(state.mRevenuePoolA, state.mCurrentGovParams.maintenancePercent), QRWA_PERCENT_DENOMINATOR);
                    if (locals.maintenancePayout > 0 && state.mCurrentGovParams.maintenanceAddress != NULL_ID)
                    {
                        if (qpi.transfer(state.mCurrentGovParams.maintenanceAddress, locals.maintenancePayout) >= 0)
                        {
                            locals.totalFeeAmount = sadd(locals.totalFeeAmount, locals.maintenancePayout);
                        }
                        else
                        {
                            locals.logger.logType = QRWA_LOG_TYPE_ERROR;
                            locals.logger.primaryId = state.mCurrentGovParams.maintenanceAddress;
                            locals.logger.valueA = locals.maintenancePayout;
                            locals.logger.valueB = QRWA_STATUS_FAILURE_TRANSFER_FAILED;
                            LOG_INFO(locals.logger);
                        }
                    }

                    locals.reinvestmentPayout = div<uint64>(smul(state.mRevenuePoolA, state.mCurrentGovParams.reinvestmentPercent), QRWA_PERCENT_DENOMINATOR);
                    if (locals.reinvestmentPayout > 0 && state.mCurrentGovParams.reinvestmentAddress != NULL_ID)
                    {
                        if (qpi.transfer(state.mCurrentGovParams.reinvestmentAddress, locals.reinvestmentPayout) >= 0)
                        {
                            locals.totalFeeAmount = sadd(locals.totalFeeAmount, locals.reinvestmentPayout);
                        }
                        else
                        {
                            locals.logger.logType = QRWA_LOG_TYPE_ERROR;
                            locals.logger.primaryId = state.mCurrentGovParams.reinvestmentAddress;
                            locals.logger.valueA = locals.reinvestmentPayout;
                            locals.logger.valueB = QRWA_STATUS_FAILURE_TRANSFER_FAILED;
                            LOG_INFO(locals.logger);
                        }
                    }
                    state.mRevenuePoolA = (state.mRevenuePoolA > locals.totalFeeAmount) ? (state.mRevenuePoolA - locals.totalFeeAmount) : 0;
                }

                // Pool A: split remaining revenue (after gov fees) into 90% QMINE / 10% qRWA
                if (state.mRevenuePoolA > 0)
                {
                    locals.qminePortion = div<uint64>(smul(state.mRevenuePoolA, QRWA_QMINE_HOLDER_PERCENT), QRWA_PERCENT_DENOMINATOR);
                    locals.qrwaPortion = state.mRevenuePoolA - locals.qminePortion;
                    state.mPoolAQmineDividend = sadd(state.mPoolAQmineDividend, locals.qminePortion);
                    state.mPoolAQrwaDividend = sadd(state.mPoolAQrwaDividend, locals.qrwaPortion);
                    state.mRevenuePoolA = 0;
                }

                // Pool B: split revenue (no gov fees) into 90% QMINE / 10% qRWA
                if (state.mRevenuePoolB > 0)
                {
                    locals.qminePortion = div<uint64>(smul(state.mRevenuePoolB, QRWA_QMINE_HOLDER_PERCENT), QRWA_PERCENT_DENOMINATOR);
                    locals.qrwaPortion = state.mRevenuePoolB - locals.qminePortion;
                    state.mPoolBQmineDividend = sadd(state.mPoolBQmineDividend, locals.qminePortion);
                    state.mPoolBQrwaDividend = sadd(state.mPoolBQrwaDividend, locals.qrwaPortion);
                    state.mRevenuePoolB = 0;
                }

                // Pool C: split dedicated revenue into 90% QMINE / 10% dedicated qRWA
                if (state.mDedicatedRevenuePool > 0)
                {
                    locals.qminePortion = div<uint64>(smul(state.mDedicatedRevenuePool, QRWA_QMINE_HOLDER_PERCENT), QRWA_PERCENT_DENOMINATOR);
                    locals.qrwaPortion = state.mDedicatedRevenuePool - locals.qminePortion;
                    state.mPoolCQmineDividend = sadd(state.mPoolCQmineDividend, locals.qminePortion);
                    state.mPoolCQrwaDividend = sadd(state.mPoolCQrwaDividend, locals.qrwaPortion);
                    state.mDedicatedRevenuePool = 0;
                }

                // ──── QMINE distribution: single pass over holders, distribute from 3 pools ────
                locals.poolAQmine_128 = state.mPoolAQmineDividend;
                locals.poolBQmine_128 = state.mPoolBQmineDividend;
                locals.poolCQmine_128 = state.mPoolCQmineDividend;

                if ((locals.poolAQmine_128 > (uint128)0 || locals.poolBQmine_128 > (uint128)0 || locals.poolCQmine_128 > (uint128)0) && state.mPayoutTotalQmineBegin > 0)
                {
                    locals.qminePayoutIndex = NULL_INDEX;

                    while (true)
                    {
                        locals.qminePayoutIndex = state.mPayoutBeginBalances.nextElementIndex(locals.qminePayoutIndex);
                        if (locals.qminePayoutIndex == NULL_INDEX)
                        {
                            break;
                        }

                        locals.holder = state.mPayoutBeginBalances.key(locals.qminePayoutIndex);
                        locals.beginBalance = state.mPayoutBeginBalances.value(locals.qminePayoutIndex);

                        if (state.mFundraisingAddress != NULL_ID && locals.holder == state.mFundraisingAddress)
                        {
                            continue;
                        }

                        locals.foundEnd = state.mPayoutEndBalances.get(locals.holder, locals.endBalance) ? 1 : 0;
                        if (locals.foundEnd == 0)
                        {
                            locals.endBalance = 0;
                        }

                        locals.eligibleBalance = (locals.endBalance >= locals.beginBalance) ? locals.beginBalance : 0;

                        if (locals.eligibleBalance > 0)
                        {
                            // ── Pool A QMINE payout ──
                            if (locals.poolAQmine_128 > (uint128)0)
                            {
                                locals.scaledPayout_128 = (uint128)locals.eligibleBalance * (uint128)state.mPoolAQmineDividend;
                                locals.eligiblePayout_128 = div<uint128>(locals.scaledPayout_128, state.mPayoutTotalQmineBegin);
                                if (locals.eligiblePayout_128 > locals.poolAQmine_128)
                                {
                                    locals.eligiblePayout_128 = locals.poolAQmine_128;
                                }
                                if (locals.eligiblePayout_128 > (uint128)0 && locals.eligiblePayout_128.high == 0)
                                {
                                    locals.payout_u64 = locals.eligiblePayout_128.low;
                                    if (locals.payout_u64 > 0 && qpi.transfer(locals.holder, (sint64)locals.payout_u64) >= 0)
                                    {
                                        locals.poolAQmine_128 -= locals.eligiblePayout_128;
                                        state.mTotalPoolADistributed = sadd(state.mTotalPoolADistributed, locals.payout_u64);
                                        locals.payoutEntry.recipient = locals.holder;
                                        locals.payoutEntry.amount = locals.payout_u64;
                                        locals.payoutEntry.qmineHolding = locals.eligibleBalance;
                                        locals.payoutEntry.qrwaHolding = 0;
                                        locals.payoutEntry.tick = qpi.tick();
                                        locals.payoutEntry.epoch = qpi.epoch();
                                        locals.payoutEntry.payoutType = QRWA_PAYOUT_TYPE_QMINE_HOLDER;
                                        state.mPayoutsPoolA.set(state.mPayoutsPoolANextIdx, locals.payoutEntry);
                                        state.mPayoutsPoolANextIdx = (state.mPayoutsPoolANextIdx + 1) & (QRWA_PAYOUT_RING_SIZE - 1);
                                    }
                                }
                            }

                            // ── Pool B QMINE payout ──
                            if (locals.poolBQmine_128 > (uint128)0)
                            {
                                locals.scaledPayout_128 = (uint128)locals.eligibleBalance * (uint128)state.mPoolBQmineDividend;
                                locals.eligiblePayout_128 = div<uint128>(locals.scaledPayout_128, state.mPayoutTotalQmineBegin);
                                if (locals.eligiblePayout_128 > locals.poolBQmine_128)
                                {
                                    locals.eligiblePayout_128 = locals.poolBQmine_128;
                                }
                                if (locals.eligiblePayout_128 > (uint128)0 && locals.eligiblePayout_128.high == 0)
                                {
                                    locals.payout_u64 = locals.eligiblePayout_128.low;
                                    if (locals.payout_u64 > 0 && qpi.transfer(locals.holder, (sint64)locals.payout_u64) >= 0)
                                    {
                                        locals.poolBQmine_128 -= locals.eligiblePayout_128;
                                        state.mTotalPoolBDistributed = sadd(state.mTotalPoolBDistributed, locals.payout_u64);
                                        locals.payoutEntry.recipient = locals.holder;
                                        locals.payoutEntry.amount = locals.payout_u64;
                                        locals.payoutEntry.qmineHolding = locals.eligibleBalance;
                                        locals.payoutEntry.qrwaHolding = 0;
                                        locals.payoutEntry.tick = qpi.tick();
                                        locals.payoutEntry.epoch = qpi.epoch();
                                        locals.payoutEntry.payoutType = QRWA_PAYOUT_TYPE_QMINE_HOLDER;
                                        state.mPayoutsPoolB.set(state.mPayoutsPoolBNextIdx, locals.payoutEntry);
                                        state.mPayoutsPoolBNextIdx = (state.mPayoutsPoolBNextIdx + 1) & (QRWA_PAYOUT_RING_SIZE - 1);
                                    }
                                }
                            }

                            // ── Pool C QMINE payout ──
                            if (locals.poolCQmine_128 > (uint128)0)
                            {
                                locals.scaledPayout_128 = (uint128)locals.eligibleBalance * (uint128)state.mPoolCQmineDividend;
                                locals.eligiblePayout_128 = div<uint128>(locals.scaledPayout_128, state.mPayoutTotalQmineBegin);
                                if (locals.eligiblePayout_128 > locals.poolCQmine_128)
                                {
                                    locals.eligiblePayout_128 = locals.poolCQmine_128;
                                }
                                if (locals.eligiblePayout_128 > (uint128)0 && locals.eligiblePayout_128.high == 0)
                                {
                                    locals.payout_u64 = locals.eligiblePayout_128.low;
                                    if (locals.payout_u64 > 0 && qpi.transfer(locals.holder, (sint64)locals.payout_u64) >= 0)
                                    {
                                        locals.poolCQmine_128 -= locals.eligiblePayout_128;
                                        state.mTotalPoolCDistributed = sadd(state.mTotalPoolCDistributed, locals.payout_u64);
                                        locals.payoutEntry.recipient = locals.holder;
                                        locals.payoutEntry.amount = locals.payout_u64;
                                        locals.payoutEntry.qmineHolding = locals.eligibleBalance;
                                        locals.payoutEntry.qrwaHolding = 0;
                                        locals.payoutEntry.tick = qpi.tick();
                                        locals.payoutEntry.epoch = qpi.epoch();
                                        locals.payoutEntry.payoutType = QRWA_PAYOUT_TYPE_QMINE_HOLDER;
                                        state.mPayoutsPoolC.set(state.mPayoutsPoolCNextIdx, locals.payoutEntry);
                                        state.mPayoutsPoolCNextIdx = (state.mPayoutsPoolCNextIdx + 1) & (QRWA_PAYOUT_RING_SIZE - 1);
                                    }
                                }
                            }
                        }
                    }

                    // Dev payout: remainder of each pool's QMINE leg
                    if (state.mCurrentGovParams.qmineDevAddress != NULL_ID)
                    {
                        // Pool A dev
                        if (locals.poolAQmine_128 > (uint128)0 && locals.poolAQmine_128.high == 0)
                        {
                            locals.payout_u64 = locals.poolAQmine_128.low;
                            if (locals.payout_u64 > 0 && qpi.transfer(state.mCurrentGovParams.qmineDevAddress, (sint64)locals.payout_u64) >= 0)
                            {
                                state.mTotalPoolADistributed = sadd(state.mTotalPoolADistributed, locals.payout_u64);
                                locals.poolAQmine_128 = 0;
                                locals.payoutEntry.recipient = state.mCurrentGovParams.qmineDevAddress;
                                locals.payoutEntry.amount = locals.payout_u64;
                                locals.payoutEntry.qmineHolding = 0;
                                locals.payoutEntry.qrwaHolding = 0;
                                locals.payoutEntry.tick = qpi.tick();
                                locals.payoutEntry.epoch = qpi.epoch();
                                locals.payoutEntry.payoutType = QRWA_PAYOUT_TYPE_QMINE_DEV;
                                state.mPayoutsPoolA.set(state.mPayoutsPoolANextIdx, locals.payoutEntry);
                                state.mPayoutsPoolANextIdx = (state.mPayoutsPoolANextIdx + 1) & (QRWA_PAYOUT_RING_SIZE - 1);
                            }
                        }
                        // Pool B dev
                        if (locals.poolBQmine_128 > (uint128)0 && locals.poolBQmine_128.high == 0)
                        {
                            locals.payout_u64 = locals.poolBQmine_128.low;
                            if (locals.payout_u64 > 0 && qpi.transfer(state.mCurrentGovParams.qmineDevAddress, (sint64)locals.payout_u64) >= 0)
                            {
                                state.mTotalPoolBDistributed = sadd(state.mTotalPoolBDistributed, locals.payout_u64);
                                locals.poolBQmine_128 = 0;
                                locals.payoutEntry.recipient = state.mCurrentGovParams.qmineDevAddress;
                                locals.payoutEntry.amount = locals.payout_u64;
                                locals.payoutEntry.qmineHolding = 0;
                                locals.payoutEntry.qrwaHolding = 0;
                                locals.payoutEntry.tick = qpi.tick();
                                locals.payoutEntry.epoch = qpi.epoch();
                                locals.payoutEntry.payoutType = QRWA_PAYOUT_TYPE_QMINE_DEV;
                                state.mPayoutsPoolB.set(state.mPayoutsPoolBNextIdx, locals.payoutEntry);
                                state.mPayoutsPoolBNextIdx = (state.mPayoutsPoolBNextIdx + 1) & (QRWA_PAYOUT_RING_SIZE - 1);
                            }
                        }
                        // Pool C dev
                        if (locals.poolCQmine_128 > (uint128)0 && locals.poolCQmine_128.high == 0)
                        {
                            locals.payout_u64 = locals.poolCQmine_128.low;
                            if (locals.payout_u64 > 0 && qpi.transfer(state.mCurrentGovParams.qmineDevAddress, (sint64)locals.payout_u64) >= 0)
                            {
                                state.mTotalPoolCDistributed = sadd(state.mTotalPoolCDistributed, locals.payout_u64);
                                locals.poolCQmine_128 = 0;
                                locals.payoutEntry.recipient = state.mCurrentGovParams.qmineDevAddress;
                                locals.payoutEntry.amount = locals.payout_u64;
                                locals.payoutEntry.qmineHolding = 0;
                                locals.payoutEntry.qrwaHolding = 0;
                                locals.payoutEntry.tick = qpi.tick();
                                locals.payoutEntry.epoch = qpi.epoch();
                                locals.payoutEntry.payoutType = QRWA_PAYOUT_TYPE_QMINE_DEV;
                                state.mPayoutsPoolC.set(state.mPayoutsPoolCNextIdx, locals.payoutEntry);
                                state.mPayoutsPoolCNextIdx = (state.mPayoutsPoolCNextIdx + 1) & (QRWA_PAYOUT_RING_SIZE - 1);
                            }
                        }
                    }

                    // Preserve undistributed remainder if transfers failed
                    state.mPoolAQmineDividend = locals.poolAQmine_128.low;
                    state.mPoolBQmineDividend = locals.poolBQmine_128.low;
                    state.mPoolCQmineDividend = locals.poolCQmine_128.low;
                } // End QMINE distribution

                // ──── qRWA distribution (Pool A + Pool B): single pass over qRWA holders ────
                if (state.mPoolAQrwaDividend > 0 || state.mPoolBQrwaDividend > 0)
                {
                    locals.qrwaAsset.issuer = id::zero();
                    locals.qrwaAsset.assetName = QRWA_CONTRACT_ASSET_NAME;
                    locals.eligibleShares = 0;

                    // First pass: count eligible shares
                    for (locals.qrwaIter.begin(locals.qrwaAsset); !locals.qrwaIter.reachedEnd(); locals.qrwaIter.next())
                    {
                        locals.qrwaShares = static_cast<uint64>(locals.qrwaIter.numberOfPossessedShares());
                        if (locals.qrwaShares == 0) continue;
                        locals.holder = locals.qrwaIter.possessor();
                        if (locals.holder == SELF) continue;
                        if (state.mFundraisingAddress != NULL_ID && locals.holder == state.mFundraisingAddress) continue;
                        locals.eligibleShares = sadd(locals.eligibleShares, locals.qrwaShares);
                    }

                    if (locals.eligibleShares > 0)
                    {
                        locals.poolAAmountPerShare = (state.mPoolAQrwaDividend > 0) ? div<uint64>(state.mPoolAQrwaDividend, locals.eligibleShares) : 0;
                        locals.poolBAmountPerShare = (state.mPoolBQrwaDividend > 0) ? div<uint64>(state.mPoolBQrwaDividend, locals.eligibleShares) : 0;

                        if (locals.poolAAmountPerShare > 0 || locals.poolBAmountPerShare > 0)
                        {
                            locals.poolAQrwaDistributed = 0;
                            locals.poolBQrwaDistributed = 0;

                            // Second pass: distribute to eligible holders
                            for (locals.qrwaIter.begin(locals.qrwaAsset); !locals.qrwaIter.reachedEnd(); locals.qrwaIter.next())
                            {
                                locals.qrwaShares = static_cast<uint64>(locals.qrwaIter.numberOfPossessedShares());
                                if (locals.qrwaShares == 0) continue;
                                locals.holder = locals.qrwaIter.possessor();
                                if (locals.holder == SELF) continue;
                                if (state.mFundraisingAddress != NULL_ID && locals.holder == state.mFundraisingAddress) continue;

                                // Pool A qRWA payout
                                if (locals.poolAAmountPerShare > 0)
                                {
                                    locals.payout_u64 = smul(locals.poolAAmountPerShare, locals.qrwaShares);
                                    if (locals.payout_u64 > 0 && qpi.transfer(locals.holder, static_cast<sint64>(locals.payout_u64)) >= 0)
                                    {
                                        locals.poolAQrwaDistributed = sadd(locals.poolAQrwaDistributed, locals.payout_u64);
                                        state.mTotalPoolADistributed = sadd(state.mTotalPoolADistributed, locals.payout_u64);
                                        locals.payoutEntry.recipient = locals.holder;
                                        locals.payoutEntry.amount = locals.payout_u64;
                                        locals.payoutEntry.qmineHolding = 0;
                                        locals.payoutEntry.qrwaHolding = locals.qrwaShares;
                                        locals.payoutEntry.tick = qpi.tick();
                                        locals.payoutEntry.epoch = qpi.epoch();
                                        locals.payoutEntry.payoutType = QRWA_PAYOUT_TYPE_QRWA_HOLDER;
                                        state.mPayoutsPoolA.set(state.mPayoutsPoolANextIdx, locals.payoutEntry);
                                        state.mPayoutsPoolANextIdx = (state.mPayoutsPoolANextIdx + 1) & (QRWA_PAYOUT_RING_SIZE - 1);
                                    }
                                }

                                // Pool B qRWA payout
                                if (locals.poolBAmountPerShare > 0)
                                {
                                    locals.payout_u64 = smul(locals.poolBAmountPerShare, locals.qrwaShares);
                                    if (locals.payout_u64 > 0 && qpi.transfer(locals.holder, static_cast<sint64>(locals.payout_u64)) >= 0)
                                    {
                                        locals.poolBQrwaDistributed = sadd(locals.poolBQrwaDistributed, locals.payout_u64);
                                        state.mTotalPoolBDistributed = sadd(state.mTotalPoolBDistributed, locals.payout_u64);
                                        locals.payoutEntry.recipient = locals.holder;
                                        locals.payoutEntry.amount = locals.payout_u64;
                                        locals.payoutEntry.qmineHolding = 0;
                                        locals.payoutEntry.qrwaHolding = locals.qrwaShares;
                                        locals.payoutEntry.tick = qpi.tick();
                                        locals.payoutEntry.epoch = qpi.epoch();
                                        locals.payoutEntry.payoutType = QRWA_PAYOUT_TYPE_QRWA_HOLDER;
                                        state.mPayoutsPoolB.set(state.mPayoutsPoolBNextIdx, locals.payoutEntry);
                                        state.mPayoutsPoolBNextIdx = (state.mPayoutsPoolBNextIdx + 1) & (QRWA_PAYOUT_RING_SIZE - 1);
                                    }
                                }
                            }

                            // Update Pool A qRWA dividend remainder
                            state.mPoolAQrwaDividend = (state.mPoolAQrwaDividend > locals.poolAQrwaDistributed)
                                ? (state.mPoolAQrwaDividend - locals.poolAQrwaDistributed) : 0;
                            // Update Pool B qRWA dividend remainder
                            state.mPoolBQrwaDividend = (state.mPoolBQrwaDividend > locals.poolBQrwaDistributed)
                                ? (state.mPoolBQrwaDividend - locals.poolBQrwaDistributed) : 0;
                        }
                    }
                }

                // ──── Dedicated qRWA distribution (Pool C): requires >= 100K QMINE per qRWA share ────
                if (state.mPoolCQrwaDividend > 0)
                {
                    locals.qrwaAsset.issuer = id::zero();
                    locals.qrwaAsset.assetName = QRWA_CONTRACT_ASSET_NAME;
                    locals.dedicatedEligibleShares = 0;

                    for (locals.qrwaIter.begin(locals.qrwaAsset); !locals.qrwaIter.reachedEnd(); locals.qrwaIter.next())
                    {
                        locals.qrwaShares = static_cast<uint64>(locals.qrwaIter.numberOfPossessedShares());
                        if (locals.qrwaShares == 0) continue;
                        locals.holder = locals.qrwaIter.possessor();
                        if (locals.holder == SELF) continue;
                        if (state.mFundraisingAddress != NULL_ID && locals.holder == state.mFundraisingAddress) continue;

                        locals.qmineBalance = qpi.numberOfShares(
                            state.mQmineAsset,
                            AssetOwnershipSelect::byOwner(locals.holder),
                            AssetPossessionSelect::byPossessor(locals.holder)
                        );
                        if (locals.qmineBalance <= 0) continue;

                        locals.requiredQmine = smul(locals.qrwaShares, QRWA_QMINE_PER_QRWA_SHARE_MIN);
                        if (static_cast<uint64>(locals.qmineBalance) >= locals.requiredQmine)
                        {
                            locals.dedicatedEligibleShares = sadd(locals.dedicatedEligibleShares, locals.qrwaShares);
                        }
                    }

                    if (locals.dedicatedEligibleShares > 0)
                    {
                        locals.dedicatedAmountPerShare = div<uint64>(state.mPoolCQrwaDividend, locals.dedicatedEligibleShares);
                        if (locals.dedicatedAmountPerShare > 0)
                        {
                            locals.dedicatedDistributed = 0;
                            for (locals.qrwaIter.begin(locals.qrwaAsset); !locals.qrwaIter.reachedEnd(); locals.qrwaIter.next())
                            {
                                locals.qrwaShares = static_cast<uint64>(locals.qrwaIter.numberOfPossessedShares());
                                if (locals.qrwaShares == 0) continue;
                                locals.holder = locals.qrwaIter.possessor();
                                if (locals.holder == SELF) continue;
                                if (state.mFundraisingAddress != NULL_ID && locals.holder == state.mFundraisingAddress) continue;

                                locals.qmineBalance = qpi.numberOfShares(
                                    state.mQmineAsset,
                                    AssetOwnershipSelect::byOwner(locals.holder),
                                    AssetPossessionSelect::byPossessor(locals.holder)
                                );
                                if (locals.qmineBalance <= 0) continue;

                                locals.requiredQmine = smul(locals.qrwaShares, QRWA_QMINE_PER_QRWA_SHARE_MIN);
                                if (static_cast<uint64>(locals.qmineBalance) < locals.requiredQmine) continue;

                                locals.payout_u64 = smul(locals.dedicatedAmountPerShare, locals.qrwaShares);
                                if (locals.payout_u64 > 0 && qpi.transfer(locals.holder, static_cast<sint64>(locals.payout_u64)) >= 0)
                                {
                                    locals.dedicatedDistributed = sadd(locals.dedicatedDistributed, locals.payout_u64);
                                    state.mTotalPoolCDistributed = sadd(state.mTotalPoolCDistributed, locals.payout_u64);
                                    locals.payoutEntry.recipient = locals.holder;
                                    locals.payoutEntry.amount = locals.payout_u64;
                                    locals.payoutEntry.qmineHolding = static_cast<uint64>(locals.qmineBalance);
                                    locals.payoutEntry.qrwaHolding = locals.qrwaShares;
                                    locals.payoutEntry.tick = qpi.tick();
                                    locals.payoutEntry.epoch = qpi.epoch();
                                    locals.payoutEntry.payoutType = QRWA_PAYOUT_TYPE_DEDICATED_QRWA;
                                    state.mPayoutsPoolC.set(state.mPayoutsPoolCNextIdx, locals.payoutEntry);
                                    state.mPayoutsPoolCNextIdx = (state.mPayoutsPoolCNextIdx + 1) & (QRWA_PAYOUT_RING_SIZE - 1);
                                }
                            }

                            state.mPoolCQrwaDividend = (state.mPoolCQrwaDividend > locals.dedicatedDistributed)
                                ? (state.mPoolCQrwaDividend - locals.dedicatedDistributed) : 0;
                        }
                    }
                }

                // Update last payout time/tick
                state.mLastPayoutTime = qpi.now();
                state.mLastPayoutTick = qpi.tick();
                locals.logger.logType = QRWA_LOG_TYPE_DISTRIBUTION;
                locals.logger.primaryId = NULL_ID;
                locals.logger.valueA = 1; // Indicate success
                locals.logger.valueB = 0;
                LOG_INFO(locals.logger);
        }
    }

    struct POST_INCOMING_TRANSFER_locals
    {
        QRWALogger logger;
        uint64 prevCumulative;
    };
    POST_INCOMING_TRANSFER_WITH_LOCALS()
    {
        // SC dividend routing: if a held SC distributes dividends (type 3), always → Pool B
        if (input.type == TransferType::qpiDistributeDividends)
        {
            state.mRevenuePoolB = sadd(state.mRevenuePoolB, static_cast<uint64>(input.amount));
            // Update cumulative SC dividend tracker
            state.mScDividendTracker.get(input.sourceId, locals.prevCumulative);
            state.mScDividendTracker.set(input.sourceId, sadd(locals.prevCumulative, static_cast<uint64>(input.amount)));
            locals.logger.contractId = CONTRACT_INDEX;
            locals.logger.logType = QRWA_LOG_TYPE_INCOMING_SC_DIVIDEND;
            locals.logger.primaryId = input.sourceId;
            locals.logger.valueA = input.amount;
            locals.logger.valueB = sadd(locals.prevCumulative, static_cast<uint64>(input.amount));
            LOG_INFO(locals.logger);
            return;
        }

        // Revenue routing:
        // Pool A: mPoolARevenueAddress (QMINE issuer / mining revenue)
        // Pool C: Dedicated BTC revenue address (mDedicatedRevenueAddress)
        // Pool B: Everything else (users, other contracts)
        if (state.mDedicatedRevenueAddress != NULL_ID && input.sourceId == state.mDedicatedRevenueAddress)
        {
            // Pool C: Dedicated BTC revenue address
            state.mDedicatedRevenuePool = sadd(state.mDedicatedRevenuePool, static_cast<uint64>(input.amount));
            locals.logger.contractId = CONTRACT_INDEX;
            locals.logger.logType = QRWA_LOG_TYPE_INCOMING_REVENUE_DEDICATED;
            locals.logger.primaryId = input.sourceId;
            locals.logger.valueA = input.amount;
            locals.logger.valueB = input.type;
            LOG_INFO(locals.logger);
        }
        else if (state.mPoolARevenueAddress != NULL_ID && input.sourceId == state.mPoolARevenueAddress)
        {
            // Pool A: Direct transfer from Pool A revenue address only
            state.mRevenuePoolA = sadd(state.mRevenuePoolA, static_cast<uint64>(input.amount));
            locals.logger.contractId = CONTRACT_INDEX;
            locals.logger.logType = QRWA_LOG_TYPE_INCOMING_REVENUE_A;
            locals.logger.primaryId = input.sourceId;
            locals.logger.valueA = input.amount;
            locals.logger.valueB = input.type;
            LOG_INFO(locals.logger);
        }
        else if (input.sourceId != NULL_ID)
        {
            // Pool B: All other sources (users, other contracts)
            state.mRevenuePoolB = sadd(state.mRevenuePoolB, static_cast<uint64>(input.amount));
            locals.logger.contractId = CONTRACT_INDEX;
            locals.logger.logType = QRWA_LOG_TYPE_INCOMING_REVENUE_B;
            locals.logger.primaryId = input.sourceId;
            locals.logger.valueA = input.amount;
            locals.logger.valueB = input.type;
            LOG_INFO(locals.logger);
        }
    }

    PRE_ACQUIRE_SHARES()
    {
        // Allow any entity to transfer asset management rights to this contract
        output.requestedFee = 0;
        output.allowTransfer = true;
    }

    struct POST_ACQUIRE_SHARES_locals
    {
        sint64 transferResult;
        uint64 currentAssetBalance;
        QRWAAsset wrapper;
        QRWALogger logger;
    };
    POST_ACQUIRE_SHARES_WITH_LOCALS()
    {
        // Automatically lock shares permanently: transfer ownership+possession from
        // the previous owner/possessor to SELF and record in mGeneralAssetBalances.
        // This allows any user to deposit SC shares in 2 steps:
        //   1. Buy shares on QX
        //   2. Transfer management rights to qRWA (this callback fires automatically)
        locals.transferResult = qpi.transferShareOwnershipAndPossession(
            input.asset.assetName,
            input.asset.issuer,
            input.owner,          // current owner
            input.possessor,      // current possessor
            input.numberOfShares,
            SELF                  // new owner and possessor (permanent lock)
        );

        locals.logger.contractId = CONTRACT_INDEX;
        locals.logger.logType = QRWA_LOG_TYPE_ADMIN_ACTION;
        locals.logger.primaryId = input.owner;
        locals.logger.valueA = input.asset.assetName;

        if (locals.transferResult >= 0)
        {
            locals.wrapper.setFrom(input.asset);
            state.mGeneralAssetBalances.get(locals.wrapper, locals.currentAssetBalance); // 0 if not present
            locals.currentAssetBalance = sadd(locals.currentAssetBalance, (uint64)input.numberOfShares);
            state.mGeneralAssetBalances.set(locals.wrapper, locals.currentAssetBalance);

            // Register the asset issuer (SC contract ID) in the dividend tracker
            // so POST_INCOMING_TRANSFER can recognize its dividends.
            if (!state.mScDividendTracker.get(input.asset.issuer, locals.currentAssetBalance))
            {
                state.mScDividendTracker.set(input.asset.issuer, 0);
            }

            locals.logger.valueB = QRWA_STATUS_SUCCESS;
        }
        else
        {
            locals.logger.valueB = QRWA_STATUS_FAILURE_TRANSFER_FAILED;
        }

        LOG_INFO(locals.logger);
    }

    REGISTER_USER_FUNCTIONS_AND_PROCEDURES()
    {
        // PROCEDURES
        REGISTER_USER_PROCEDURE(DonateToTreasury, 3);
        REGISTER_USER_PROCEDURE(VoteGovParams, 4);
        REGISTER_USER_PROCEDURE(DepositGeneralAsset, 7);
        REGISTER_USER_PROCEDURE(RevokeAssetManagementRights, 8);
        REGISTER_USER_PROCEDURE(SetPoolARevenueAddress, 9);

        // FUNCTIONS
        REGISTER_USER_FUNCTION(GetGovParams, 1);
        REGISTER_USER_FUNCTION(GetGovPoll, 2);
        REGISTER_USER_FUNCTION(GetTreasuryBalance, 4);
        REGISTER_USER_FUNCTION(GetDividendBalances, 5);
        REGISTER_USER_FUNCTION(GetTotalDistributed, 6);
        REGISTER_USER_FUNCTION(GetActiveGovPollIds, 8);
        REGISTER_USER_FUNCTION(GetGeneralAssetBalance, 9);
        REGISTER_USER_FUNCTION(GetGeneralAssets, 10);
        REGISTER_USER_FUNCTION(GetPayoutsQmine, 11);
        REGISTER_USER_FUNCTION(GetContractAddresses, 12);
        REGISTER_USER_FUNCTION(GetPayoutsQrwa, 13);
        REGISTER_USER_FUNCTION(GetPayoutsDedicated, 14);
        REGISTER_USER_FUNCTION(GetScDividendTracking, 15);

    }
};
