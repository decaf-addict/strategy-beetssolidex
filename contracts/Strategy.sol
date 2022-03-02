// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";
import "../interfaces/BalancerV2.sol";
import "../interfaces/Beethoven.sol";

interface ISolidlyRouter {
    function addLiquidity(
        address,
        address,
        bool,
        uint256,
        uint256,
        uint256,
        uint256,
        address,
        uint256
    )
    external
    returns (
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    );

    function removeLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function quoteRemoveLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 liquidity
    ) external view returns (uint256 amountA, uint256 amountB);
}

interface ITradeFactory {
    function enable(address, address) external;
}

interface ILpDepositer {
    function deposit(address pool, uint256 _amount) external;

    function withdraw(address pool, uint256 _amount) external; // use amount = 0 for harvesting rewards

    function userBalances(address user, address pool)
    external
    view
    returns (uint256);

    function getReward(address[] memory lps) external;
}

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    ISolidlyRouter internal constant solidlyRouter = ISolidlyRouter(0xa38cd27185a464914D3046f0AB9d43356B34829D);
    IERC20 internal constant sex = IERC20(0xD31Fcd1f7Ba190dBc75354046F6024A9b86014d7);
    IERC20 internal constant solid = IERC20(0x888EF71766ca594DED1F0FA3AE64eD2941740A20);
    IERC20 public solidlyLp = IERC20(0x5A3AA3284EE642152D4a2B55BE1160051c5eB932);
    ILpDepositer public lpDepositer = ILpDepositer(0x26E1A0d851CF28E697870e1b7F053B605C8b060F);
    IBeetsBar public constant fBeets = IBeetsBar(0xfcef8a994209d6916EB2C86cDD2AFD60Aa6F54b1);
    IBalancerPool public constant beetsLp = IBalancerPool(0xcdE5a11a4ACB4eE4c805352Cec57E236bdBC3837);
    IERC20 public constant beets = IERC20(0xF24Bcf4d1e507740041C9cFd2DddB29585aDCe1e);
    IERC20 public constant wftm = IERC20(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);

    IBalancerVault public bVault;

    uint256 public maxSlippageIn; // bips
    uint256 public maxSlippageOut; // bips

    uint256 internal constant max = type(uint256).max;
    uint256 internal constant basisOne = 10000;
    SwapSteps internal swapSteps;

    struct SwapSteps {
        bytes32[] poolIds;
        IAsset[] assets;
    }

    constructor(address _vault, address _bVault) public BaseStrategy(_vault) {
        bVault = IBalancerVault(_bVault);
    }

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "beets-fBeets solidex";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant();
    }

    function prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss, uint256 _debtPayment){
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;
        uint256 totalAssetsAfterProfit = estimatedTotalAssets();

        _profit = totalAssetsAfterProfit > totalDebt ? totalAssetsAfterProfit.sub(totalDebt) : 0;

        uint256 _amountFreed;
        uint256 _toLiquidate = _debtOutstanding.add(_profit);
        if (_toLiquidate > 0) {
            (_amountFreed, _loss) = liquidatePosition(_toLiquidate);
        }

        _debtPayment = Math.min(_debtOutstanding, _amountFreed);

        if (_loss > _profit) {
            // Example:
            // debtOutstanding 100, profit 50, _amountFreed 100, _loss 50
            // loss should be 0, (50-50)
            // profit should endup in 0
            _loss = _loss.sub(_profit);
            _profit = 0;
        } else {
            // Example:
            // debtOutstanding 100, profit 50, _amountFreed 140, _loss 10
            // _profit should be 40, (50 profit - 10 loss)
            // loss should end up in 0
            _profit = _profit.sub(_loss);
            _loss = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint beetsBalance = beets.balanceOf(lpToken);
        uint fBeetsBalance = fBeets.balanceOf(lpToken);
        uint ratioSolidlyPool = beetsBalance.mul(1e18).div(fBeetsBalance);

        _createBeetsLp(balanceOfReward().div(2));
        _mintFBeets(balanceOfBeetsLp());
        _lpSolidly();
        _farmSolidex();
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss){
        uint256 totalAssets = want.balanceOf(address(this));
        if (_amountNeeded > totalAssets) {
            _liquidatedAmount = totalAssets;
            _loss = _amountNeeded.sub(totalAssets);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        _sellBeetsLp();
        return balanceOfWant();
    }


    function prepareMigration(address _newStrategy) internal override {
    }


    function protectedTokens() internal view override returns (address[] memory){}


    function ethToWant(uint256 _amtInWei) public view virtual override returns (uint256){
        return 0;
    }

    // HELPERS //

    // beets
    function balanceOfWant() public view returns (uint256 _amount){
        return want.balanceOf(address(this));
    }

    function balanceOfFBeets() public view returns (uint256 _amount){
        return fBeets.balanceOf(address(this));
    }

    function balanceOfBeetsLp() public view returns (uint256 _amount){
        return beetsLp.balanceOf(address(this));
    }

    function balanceOfSolidlyLp() public view returns (uint256 _amount){
        return solidlyLp.balanceOf(address(this));
    }

    function balanceOfSolidlyLpInSolidex() public view returns (uint256 _amount){
        return lpDepositer.userBalances(address(this), solidlyLp);
    }


    function createBeetsLp(uint _beets) external onlyVaultManagers {
        _createBeetsLp(_beets);
    }

    // beets --> beetsLP (beets-wftm lp)
    function _createBeetsLp(uint _beets) internal {
        if (_beets > 0) {
            uint256[] memory maxAmountsIn = new uint256[](2);
            maxAmountsIn[1] = _beets;
            uint256 beetsLps = _beets.mul(1e18).div(beetsLp.getRate());
            uint256 expectedLpsOut = beetsLps.mul(basisOne.sub(maxSlippageIn)).div(basisOne);

            bytes memory userData = abi.encode(IBalancerVault.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, maxAmountsIn, 0);
            IBalancerVault.JoinPoolRequest memory request = IBalancerVault.JoinPoolRequest(assets, maxAmountsIn, userData, false);
            bVault.joinPool(beetsLp.getPoolId(), address(this), address(this), request);
        }
    }

    // one sided exit of beetsLp to beets.
    function _sellBeetsLp(uint256 _beetsLps) internal {
        _beetsLps = Math.min(_beetsLps, balanceOfBpt());
        if (_beetsLps > 0) {
            uint256[] memory minAmountsOut = new uint256[](2);
            minAmountsOut[tokenIndex] = bptsToTokens(_beetsLps).mul(basisOne.sub(maxSlippageOut)).div(basisOne);
            bytes memory userData = abi.encode(IBalancerVault.ExitKind.EXACT_BPT_IN_FOR_ONE_TOKEN_OUT, _beetsLps, tokenIndex);
            IBalancerVault.ExitPoolRequest memory request = IBalancerVault.ExitPoolRequest(assets, minAmountsOut, userData, false);
            bVault.exitPool(beetsLp.getPoolId(), address(this), address(this), request);
        }
    }

    function mintFBeets(uint _beetsLps, bool _mint) external onlyVaultManagers {
        _mintFBeets(_beetsLps, _mint);
    }

    // when you have beetsLp, you can mint fBeets, or conversely burn fBeets to receive beetsLp
    function _mintFBeets(uint _beetsLps, bool _mint) internal {
        if (_mint) {
            fBeets.enter(_beetsLps);
        } else {
            fBeets.leave(_beetsLps);
        }
    }

    function lpSolidly(bool _createLp) external onlyVaultManagers {
        _lpSolidly(_createLp);
    }

    // add or remove liquidity into the beets/fBeets pool in Solidly
    function _lpSolidly(bool _createLp) internal {
        if (_createLp) {
            solidlyRouter.addLiquidity(
                address(beets),
                address(fBeets),
                false,
                balanceOfWant(),
                balanceOfFBeets(),
                0,
                0,
                address(this),
                2 ** 256 - 1
            );
        } else {
            solidlyRouter.removeLiquidity(
                address(beets),
                address(fBeets),
                false,
                balanceOfWant(),
                balanceOfFBeets(),
                0,
                0,
                address(this),
                2 ** 256 - 1
            );
        }

    }

    function farmSolidex(uint _amount, bool _enter) external onlyVaultManagers {
        _farmSolidex(_amount, _enter);
    }

    // Deposit beefs/fBeets lp into Solidex farm (lpDepositer), like entering into MasterChef farm
    function _farmSolidex(uint _amount, bool _enter) internal {
        if (_enter) {
            lpDepositer.deposit(
                solidlyLp,
                _amount
            );
        } else {
            lpDepositer.withdraw(
                solidlyLp,
                _amount
            );
        }
    }


    // SETTERS //
    function setParams(uint256 _maxSlippageIn, uint256 _maxSlippageOut, uint256 _maxSingleDeposit, uint256 _minDepositPeriod) public onlyVaultManagers {
        require(_maxSlippageIn <= basisOne);
        maxSlippageIn = _maxSlippageIn;

        require(_maxSlippageOut <= basisOne);
        maxSlippageOut = _maxSlippageOut;

    }
}
