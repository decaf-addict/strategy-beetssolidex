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

// beets (want) ->
// sell 1/2 for beetsLp (beetsLp pool) ->
// mint fBeets (beetsBar) ->
// mint solidlyLp beets/fBeets (solidly) ->
// enter farm (solidex)
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
    IBalancerVault  public bVault = IBalancerVault(0x20dd72Ed959b6147912C2e529F0a0C651c33c9ce);

    IAsset[] internal assets;

    uint256 public maxSlippageIn; // bips
    uint256 public maxSlippageOut; // bips

    uint256 internal constant max = type(uint256).max;
    uint256 internal constant basisOne = 10000;
    uint256 public secs = 180;
    uint256 public ago = 0;

    modifier isVaultManager {
        checkVaultManagers();
        _;
    }

    function checkVaultManagers() internal {
        require(msg.sender == vault.governance() || msg.sender == vault.management());
    }


    constructor(address _vault) public BaseStrategy(_vault) {
        assets = [IAsset(address(wftm)), IAsset(address(beets))];

        want.safeApprove(address(bVault), max);
        beetsLp.approve(address(fBeets), max);
        want.safeApprove(address(solidlyRouter), max);
        fBeets.approve(address(solidlyRouter), max);
        solidlyLp.approve(address(lpDepositer), max);
        solidlyLp.approve(address(solidlyRouter), max);

        maxSlippageIn = 15;
        maxSlippageOut = 15;
    }

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "beets-fBeets solidex";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        uint256 solidlyLps = balanceOfSolidlyLpInSolidex().add(balanceOfSolidlyLp());
        (uint256 beetsBalance, uint256 fBeetsBalance) = balanceOfConstituents(solidlyLps);
        // sum of lped fBeets and loose fBeets in strat
        uint256 beetsFromFBeets = estimateBeetsPerFBeets({_amount : fBeetsBalance.add(balanceOfFBeets()), _reverse : false});
        return balanceOfWant().add(beetsBalance).add(beetsFromFBeets);
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
        uint amountToLp;
        {
            uint beetsFromFBeets = estimateBeetsPerFBeets({_amount : balanceOfFBeets(), _reverse : false});
            uint looseBeets = balanceOfWant();
            uint half = looseBeets.add(beetsFromFBeets).div(2);
            amountToLp = Math.min(half, looseBeets);
        }
        if (amountToLp > 0) {
            _createBeetsLp({_beets : amountToLp});
            _beetsBar({_beetsLps : balanceOfBeetsLp(), _mint : true});
            _lpSolidly({_createLp : true});
            _farmSolidex({_amount : balanceOfSolidlyLp(), _enter : true});
        }
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss){
        uint256 totalAssets = want.balanceOf(address(this));
        if (_amountNeeded > totalAssets) {
            uint256 toExit = _amountNeeded.sub(totalAssets).mul(1e18).div(beetsPerSolidlyLp());
            toExit = Math.min(toExit, balanceOfSolidlyLpInSolidex());
            _farmSolidex({_amount : toExit, _enter : false});
            _lpSolidly({_createLp : false});
            _beetsBar({_beetsLps : balanceOfFBeets(), _mint : false});
            _sellBeetsLp({_beetsLps : balanceOfBeetsLp()});

            _liquidatedAmount = Math.min(balanceOfWant(), _amountNeeded);
            _loss = _amountNeeded.sub(_liquidatedAmount);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        _farmSolidex({_amount : balanceOfSolidlyLpInSolidex(), _enter : false});
        _lpSolidly({_createLp : false});
        _beetsBar({_beetsLps : balanceOfFBeets(), _mint : false});
        _sellBeetsLp({_beetsLps : balanceOfBeetsLp()});
        return balanceOfWant();
    }


    function prepareMigration(address _newStrategy) internal override {
        lpDepositer.withdraw(address(solidlyLp), balanceOfSolidlyLpInSolidex());
        fBeets.transfer(_newStrategy, balanceOfFBeets());
        beetsLp.transfer(_newStrategy, balanceOfBeetsLp());
        solidlyLp.transfer(_newStrategy, balanceOfSolidlyLp());
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
        return lpDepositer.userBalances(address(this), address(solidlyLp));
    }

    function balanceOfConstituents(uint256 _amount) public view returns (uint256 _beets, uint256 _fBeets){
        (_beets, _fBeets) = ISolidlyRouter(solidlyRouter).quoteRemoveLiquidity(address(beets), address(fBeets), false, _amount);
    }

    // reverse would estimate fBeets per beets
    function estimateBeetsPerFBeets(uint256 _amount, bool _reverse) public view returns (uint256){
        if (_reverse) {
            // output fbeets
            return _amount.mul(1e18).div(beetsPerBeetsLp()).mul(1e18).div(beetsLpPerFBeets());
        } else {
            // output beets
            return _amount.mul(beetsLpPerFBeets()).div(1e18).mul(beetsPerBeetsLp()).div(1e18);
        }
    }


    // @return x beets per beetsLp
    function beetsPerBeetsLp() public view returns (uint256 _amount) {
        IPriceOracle.OracleAverageQuery[] memory queries = new IPriceOracle.OracleAverageQuery[](2);
        queries[0] = IPriceOracle.OracleAverageQuery(IPriceOracle.Variable.PAIR_PRICE, secs, ago);
        queries[1] = IPriceOracle.OracleAverageQuery(IPriceOracle.Variable.BPT_PRICE, secs, ago);
        uint256[] memory results = beetsLp.getTimeWeightedAverage(queries);
        uint256 wftmPerBeets = results[0];
        uint256 wftmPerBeetsLp = results[1];
        return wftmPerBeetsLp.mul(1e18).div(wftmPerBeets);
    }

    // @return x beetsLps * 1e18 per fBeet
    function beetsLpPerFBeets() public view returns (uint256 _amount) {
        uint256 beetsLpLocked = beetsLp.balanceOf(address(fBeets));
        uint256 totalFBeets = fBeets.totalSupply();
        return beetsLpLocked.mul(1e18).div(totalFBeets);
    }

    // @return x beets per solidlyLp
    function beetsPerSolidlyLp() public view returns (uint256 _amount){
        (uint256 beets, uint256 fBeets) = balanceOfConstituents(1e18);
        return beets.add(estimateBeetsPerFBeets({_amount : fBeets, _reverse : false}));
    }


    function createBeetsLp(uint _beets) external isVaultManager {
        _createBeetsLp(_beets);
    }

    event Debug(string msg, uint value);

    // beets --> beetsLP (beets-wftm lp)
    function _createBeetsLp(uint _beets) internal {
        if (_beets > 0) {
            uint256[] memory maxAmountsIn = new uint256[](2);
            maxAmountsIn[1] = Math.min(_beets, balanceOfWant());
            uint256 beetsLps = maxAmountsIn[1].mul(1e18).div(beetsPerBeetsLp());
            uint256 expectedMinLpsOut = beetsLps.mul(basisOne.sub(maxSlippageIn)).div(basisOne);

            emit Debug("_beets", _beets);
            emit Debug("maxAmountsIn[1]", maxAmountsIn[1]);
            emit Debug("beetsLps", beetsLps);
            emit Debug("expectedMinLpsOut", expectedMinLpsOut);
            bytes memory userData = abi.encode(IBalancerVault.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, maxAmountsIn, 0);
            IBalancerVault.JoinPoolRequest memory request = IBalancerVault.JoinPoolRequest(assets, maxAmountsIn, userData, false);
            bVault.joinPool(beetsLp.getPoolId(), address(this), address(this), request);
            emit Debug("balanceOfBeetsLp", balanceOfBeetsLp());
        }
    }

    // one sided exit of beetsLp to beets.
    function _sellBeetsLp(uint256 _beetsLps) internal {
        _beetsLps = Math.min(_beetsLps, balanceOfBeetsLp());
        if (_beetsLps > 0) {
            uint256[] memory minAmountsOut = new uint256[](2);
            // calculate min out beets
            minAmountsOut[1] = _beetsLps.mul(beetsPerBeetsLp()).div(1e18).mul(basisOne.sub(maxSlippageOut)).div(basisOne);
            bytes memory userData = abi.encode(IBalancerVault.ExitKind.EXACT_BPT_IN_FOR_ONE_TOKEN_OUT, _beetsLps, 1);
            IBalancerVault.ExitPoolRequest memory request = IBalancerVault.ExitPoolRequest(assets, minAmountsOut, userData, false);
            bVault.exitPool(beetsLp.getPoolId(), address(this), address(this), request);
        }
    }

    function mintFBeets(uint _beetsLps, bool _mint) external isVaultManager {
        _beetsBar(_beetsLps, _mint);
    }

    // when you have beetsLp, you can mint fBeets, or conversely burn fBeets to receive beetsLp
    function _beetsBar(uint _beetsLps, bool _mint) internal {
        if (_beetsLps > 0) {
            if (_mint) {
                fBeets.enter(_beetsLps);
            } else {
                fBeets.leave(_beetsLps);
            }
        }
    }

    function lpSolidly(bool _createLp) external isVaultManager {
        _lpSolidly(_createLp);
    }

    // add or remove liquidity into the beets/fBeets pool in Solidly
    function _lpSolidly(bool _createLp) internal {
        if (_createLp) {
            uint256 wants = balanceOfWant();
            uint256 fBeetsAmount = balanceOfFBeets();
            if (wants > 0 && fBeetsAmount > 0) {
                solidlyRouter.addLiquidity(
                    address(beets),
                    address(fBeets),
                    false,
                    wants,
                    fBeetsAmount,
                    0,
                    0,
                    address(this),
                    2 ** 256 - 1
                );
            }
        } else {
            uint256 solidlyLps = balanceOfSolidlyLp();
            if (solidlyLps > 0) {
                solidlyRouter.removeLiquidity(
                    address(beets),
                    address(fBeets),
                    false,
                    solidlyLps,
                    0,
                    0,
                    address(this),
                    2 ** 256 - 1
                );
            }
        }
    }

    function farmSolidex(uint _amount, bool _enter) external isVaultManager {
        _farmSolidex(_amount, _enter);
    }

    // Deposit beefs/fBeets lp into Solidex farm (lpDepositer), like entering into MasterChef farm
    function _farmSolidex(uint _amount, bool _enter) internal {
        if (_amount > 0) {
            if (_enter) {
                lpDepositer.deposit(
                    address(solidlyLp),
                    _amount
                );
            } else {
                lpDepositer.withdraw(
                    address(solidlyLp),
                    _amount
                );
            }
        }
    }


    // SETTERS //

    function setTwapParams(uint256 _secs, uint256 _ago) external isVaultManager {
        secs = _secs;
        ago = _ago;
    }


    function setParams(uint256 _maxSlippageIn, uint256 _maxSlippageOut, uint256 _maxSingleDeposit, uint256 _minDepositPeriod) public isVaultManager {
        require(_maxSlippageIn <= basisOne);
        maxSlippageIn = _maxSlippageIn;

        require(_maxSlippageOut <= basisOne);
        maxSlippageOut = _maxSlippageOut;

    }

    // Balancer requires this contract to be payable, so we add ability to sweep stuck ETH
    function sweepETH() public onlyGovernance {
        (bool success,) = governance().call{value : address(this).balance}("");
        require(success, "eth");
    }

    receive() external payable {}
}
