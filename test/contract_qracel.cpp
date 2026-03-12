#define NO_UEFI

#include "contract_testing.h"

class ContractTestingQracel : protected ContractTesting
{
public:
    ContractTestingQracel()
    {
        initEmptySpectrum();
        initEmptyUniverse();
        INIT_CONTRACT(QRACEL);
    }

    QRACEL::GetConfig_output getConfig()
    {
        QRACEL::GetConfig_input input{};
        QRACEL::GetConfig_output output{};
        callFunction(QRACEL_CONTRACT_INDEX, 3, input, output);
        return output;
    }
};

TEST(QRacel, TestGetConfigRegistration)
{
    ContractTestingQracel test;
    QRACEL::GetConfig_output output = test.getConfig();
    // should return default values without crash
    EXPECT_EQ(output.roundCount, 0u);
    EXPECT_EQ(output.betCount, 0u);
    EXPECT_EQ(output.minBet, QRACEL_MIN_BET);
}
