// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.18;

import {IERC20Upgradeable, SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {MathUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import {SafeCastUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";
import {EnumerableSetUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";
import {MathUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";

import {IStakeManager, IApeCoinStaking} from "./interfaces/IStakeManager.sol";
import {INftVault} from "./interfaces/INftVault.sol";
import {ICoinPool} from "./interfaces/ICoinPool.sol";
import {INftPool} from "./interfaces/INftPool.sol";
import {IStakedNft} from "./interfaces/IStakedNft.sol";
import {IRewardsStrategy} from "./interfaces/IRewardsStrategy.sol";

import {ApeStakingLib} from "./libraries/ApeStakingLib.sol";

contract BendStakeManager is IStakeManager, OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using MathUpgradeable for uint256;
    using SafeCastUpgradeable for uint256;
    using SafeCastUpgradeable for uint248;
    using SafeCastUpgradeable for uint128;
    using ApeStakingLib for IApeCoinStaking;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.UintSet;

    uint256 public constant PERCENTAGE_FACTOR = 1e4;
    uint256 public constant MAX_FEE = 1000;
    uint256 public constant MAX_PENDING_FEE = 100 * 1e18;

    mapping(address => IRewardsStrategy) public rewardsStrategies;
    mapping(uint256 => EnumerableSetUpgradeable.UintSet) private _stakedTokenIds;
    uint256 public override fee;
    address public override feeRecipient;
    uint256 public override pendingFeeAmount;

    IApeCoinStaking public override apeCoinStaking;
    IERC20Upgradeable public apeCoin;
    INftVault public nftVault;
    ICoinPool public coinPool;
    INftPool public nftPool;
    uint256 public apeCoinPoolStakedAmount;
    address public botAdmin;

    modifier onlyBot() {
        require(_msgSender() == botAdmin, "BendStakeManager: caller is not bot admin");
        _;
    }

    modifier onlyApe(address nft_) {
        require(
            nft_ == address(apeCoinStaking.bayc()) ||
                nft_ == address(apeCoinStaking.mayc()) ||
                nft_ == address(apeCoinStaking.bakc()),
            "BendStakeManager: nft must be ape"
        );
        _;
    }

    modifier onlyCoinPoolOrBot() {
        require(
            _msgSender() == address(coinPool) || _msgSender() == botAdmin,
            "BendStakeManager: caller is not coin pool or bot admin"
        );
        _;
    }

    modifier onlyCoinPool() {
        require(_msgSender() == address(coinPool), "BendStakeManager: caller is not coin pool");
        _;
    }

    function initialize(
        IApeCoinStaking apeStaking_,
        ICoinPool coinPool_,
        INftPool nftPool_,
        INftVault nftVault_
    ) external initializer {
        __Ownable_init();
        apeCoinStaking = apeStaking_;
        coinPool = coinPool_;
        nftPool = nftPool_;
        nftVault = nftVault_;
        apeCoin = IERC20Upgradeable(apeCoinStaking.apeCoin());

        apeCoin.approve(address(apeCoinStaking), type(uint256).max);
        apeCoin.approve(address(coinPool), type(uint256).max);
        apeCoin.approve(address(nftVault), type(uint256).max);
    }

    function updateFee(uint256 fee_) external onlyOwner {
        require(fee_ >= 0 && fee_ <= 1000, "BendStakeManager: invalid fee");
        fee = fee_;
    }

    function updateFeeRecipient(address recipient_) external {
        feeRecipient = recipient_;
    }

    function _collectFee(uint256 rewardsAmount_) private returns (uint256 feeAmount) {
        if (rewardsAmount_ > 0 && fee > 0) {
            feeAmount = rewardsAmount_.mulDiv(fee, PERCENTAGE_FACTOR, MathUpgradeable.Rounding.Down);
            pendingFeeAmount += feeAmount;
        }
    }

    function _coinPoolChangedBalance(uint256 initBalance) private view returns (uint256) {
        return IERC20Upgradeable(apeCoinStaking.apeCoin()).balanceOf(address(coinPool)) - initBalance;
    }

    struct WithdrawApeCoinVars {
        uint256 margin;
        uint256 tokenId;
        uint256 size;
        uint256 totalWithdrawn;
    }

    function withdrawApeCoin(uint256 required) external override onlyCoinPool returns (uint256 withdrawn) {
        uint256 initBalance = IERC20Upgradeable(apeCoinStaking.apeCoin()).balanceOf(address(coinPool));
        // withdraw refund
        (uint256 principal, uint256 reward) = _totalRefund();
        if (principal > 0 || reward > 0) {
            _withdrawTotalRefund();
        }

        // claim ape coin pool
        if (_coinPoolChangedBalance(initBalance) < required && _pendingRewards(ApeStakingLib.APE_COIN_POOL_ID) > 0) {
            _claimApeCoin();
        }

        // unstake ape coin pool
        if (_coinPoolChangedBalance(initBalance) < required && _stakedApeCoin(ApeStakingLib.APE_COIN_POOL_ID) > 0) {
            _unstakeApeCoin(required - _coinPoolChangedBalance(initBalance));
        }
        WithdrawApeCoinVars memory vars;
        // unstake bayc
        if (_coinPoolChangedBalance(initBalance) < required && _stakedApeCoin(ApeStakingLib.BAYC_POOL_ID) > 0) {
            vars.margin = required - _coinPoolChangedBalance(initBalance);
            vars.tokenId = 0;
            vars.size = 0;
            vars.totalWithdrawn = 0;

            for (uint256 i = 0; i < _stakedTokenIds[ApeStakingLib.BAYC_POOL_ID].length(); i++) {
                vars.tokenId = _stakedTokenIds[ApeStakingLib.BAYC_POOL_ID].at(i);
                vars.totalWithdrawn += apeCoinStaking
                    .nftPosition(ApeStakingLib.BAYC_POOL_ID, vars.tokenId)
                    .stakedAmount;
                vars.totalWithdrawn += apeCoinStaking.pendingRewards(
                    ApeStakingLib.BAYC_POOL_ID,
                    address(this),
                    vars.tokenId
                );
                vars.size += 1;
                if (vars.totalWithdrawn >= vars.margin) {
                    break;
                }
            }
            if (vars.size > 0) {
                uint256[] memory tokenIds = new uint256[](vars.size);
                for (uint256 i = 0; i < vars.size; i++) {
                    tokenIds[i] = _stakedTokenIds[ApeStakingLib.BAYC_POOL_ID].at(i);
                }
                _unstakeBayc(tokenIds);
            }
        }

        // unstake mayc
        if (_coinPoolChangedBalance(initBalance) < required && _stakedApeCoin(ApeStakingLib.MAYC_POOL_ID) > 0) {
            vars.margin = required - _coinPoolChangedBalance(initBalance);
            vars.tokenId = 0;
            vars.size = 0;
            vars.totalWithdrawn = 0;
            for (uint256 i = 0; i < _stakedTokenIds[ApeStakingLib.MAYC_POOL_ID].length(); i++) {
                vars.tokenId = _stakedTokenIds[ApeStakingLib.MAYC_POOL_ID].at(i);
                vars.totalWithdrawn += apeCoinStaking
                    .nftPosition(ApeStakingLib.MAYC_POOL_ID, vars.tokenId)
                    .stakedAmount;
                vars.totalWithdrawn += apeCoinStaking.pendingRewards(
                    ApeStakingLib.MAYC_POOL_ID,
                    address(this),
                    vars.tokenId
                );
                vars.size += 1;
                if (vars.totalWithdrawn >= vars.margin) {
                    break;
                }
            }
            if (vars.size > 0) {
                uint256[] memory tokenIds = new uint256[](vars.size);
                for (uint256 i = 0; i < vars.size; i++) {
                    tokenIds[i] = _stakedTokenIds[ApeStakingLib.MAYC_POOL_ID].at(i);
                }
                _unstakeMayc(tokenIds);
            }
        }

        // unstake bakc
        if (_coinPoolChangedBalance(initBalance) < required && _stakedApeCoin(ApeStakingLib.BAKC_POOL_ID) > 0) {
            vars.margin = required - _coinPoolChangedBalance(initBalance);
            vars.tokenId = 0;
            vars.size = 0;
            vars.totalWithdrawn = 0;
            for (uint256 i = 0; i < _stakedTokenIds[ApeStakingLib.BAKC_POOL_ID].length(); i++) {
                vars.tokenId = _stakedTokenIds[ApeStakingLib.BAKC_POOL_ID].at(i);
                vars.totalWithdrawn += apeCoinStaking
                    .nftPosition(ApeStakingLib.BAKC_POOL_ID, vars.tokenId)
                    .stakedAmount;
                vars.totalWithdrawn += apeCoinStaking.pendingRewards(
                    ApeStakingLib.BAKC_POOL_ID,
                    address(this),
                    vars.tokenId
                );
                vars.size += 1;
                if (vars.totalWithdrawn >= vars.margin) {
                    break;
                }
            }
            if (vars.size > 0) {
                uint256 baycPairSize;
                uint256 baycPairIndex;
                uint256 maycPairSize;
                uint256 maycPairIndex;
                uint256 bakcTokenId;

                IApeCoinStaking.PairingStatus memory pairingStatus;
                for (uint256 i = 0; i < vars.size; i++) {
                    bakcTokenId = _stakedTokenIds[ApeStakingLib.BAKC_POOL_ID].at(i);
                    pairingStatus = apeCoinStaking.bakcToMain(bakcTokenId, ApeStakingLib.BAYC_POOL_ID);
                    if (pairingStatus.isPaired) {
                        baycPairSize += 1;
                    } else {
                        maycPairSize += 1;
                    }
                }
                IApeCoinStaking.PairNft[] memory baycPairs = new IApeCoinStaking.PairNft[](baycPairSize);
                IApeCoinStaking.PairNft[] memory maycPairs = new IApeCoinStaking.PairNft[](maycPairSize);
                for (uint256 i = 0; i < vars.size; i++) {
                    bakcTokenId = _stakedTokenIds[ApeStakingLib.BAKC_POOL_ID].at(i);
                    pairingStatus = apeCoinStaking.bakcToMain(bakcTokenId, ApeStakingLib.BAYC_POOL_ID);
                    if (pairingStatus.isPaired) {
                        baycPairs[baycPairIndex] = IApeCoinStaking.PairNft({
                            mainTokenId: pairingStatus.tokenId.toUint128(),
                            bakcTokenId: bakcTokenId.toUint128()
                        });
                        baycPairIndex += 1;
                    } else {
                        pairingStatus = apeCoinStaking.bakcToMain(bakcTokenId, ApeStakingLib.MAYC_POOL_ID);
                        maycPairs[maycPairIndex] = IApeCoinStaking.PairNft({
                            mainTokenId: pairingStatus.tokenId.toUint128(),
                            bakcTokenId: bakcTokenId.toUint128()
                        });
                        maycPairIndex += 1;
                    }
                }
                _unstakeBakc(baycPairs, maycPairs);
            }
        }

        withdrawn = _coinPoolChangedBalance(initBalance);
    }

    function updateBotAdmin(address botAdmin_) external override onlyOwner {
        botAdmin = botAdmin_;
    }

    function updateRewardsStrategy(address nft_, IRewardsStrategy rewardsStrategy_) external override onlyOwner {
        rewardsStrategies[nft_] = rewardsStrategy_;
    }

    function totalStakedApeCoin() external view override returns (uint256 amount) {
        amount += _stakedApeCoin(ApeStakingLib.APE_COIN_POOL_ID);
        amount += _stakedApeCoin(ApeStakingLib.BAYC_POOL_ID);
        amount += _stakedApeCoin(ApeStakingLib.MAYC_POOL_ID);
        amount += _stakedApeCoin(ApeStakingLib.BAKC_POOL_ID);
    }

    function totalPendingRewards() external view override returns (uint256 amount) {
        amount += _pendingRewards(ApeStakingLib.APE_COIN_POOL_ID);
        amount += _pendingRewards(ApeStakingLib.BAYC_POOL_ID);
        amount += _pendingRewards(ApeStakingLib.MAYC_POOL_ID);
        amount += _pendingRewards(ApeStakingLib.BAKC_POOL_ID);
        if (fee > 0) {
            amount = amount.mulDiv(PERCENTAGE_FACTOR - fee, PERCENTAGE_FACTOR, MathUpgradeable.Rounding.Up);
        }
    }

    function stakedApeCoin(uint256 poolId_) external view override returns (uint256) {
        return _stakedApeCoin(poolId_);
    }

    function _stakedApeCoin(uint256 poolId_) private view returns (uint256) {
        if (poolId_ == ApeStakingLib.APE_COIN_POOL_ID) {
            return apeCoinPoolStakedAmount;
        }
        return nftVault.positionOf(apeCoinStaking.nftContracts(poolId_), address(this)).stakedAmount;
    }

    function _pendingRewards(uint256 poolId_) private view returns (uint256) {
        if (poolId_ == ApeStakingLib.APE_COIN_POOL_ID) {
            return apeCoinStaking.pendingRewards(ApeStakingLib.APE_COIN_POOL_ID, address(this), 0);
        }
        return nftVault.pendingRewards(apeCoinStaking.nftContracts(poolId_), address(this));
    }

    function pendingRewards(uint256 poolId_) external view override returns (uint256 amount) {
        amount = _pendingRewards(poolId_);
        if (fee > 0) {
            amount = amount.mulDiv(PERCENTAGE_FACTOR - fee, PERCENTAGE_FACTOR, MathUpgradeable.Rounding.Up);
        }
    }

    function _prepareApeCoin(uint256 amount_) private {
        if (coinPool.pendingApeCoin() < amount_ && _pendingRewards(ApeStakingLib.APE_COIN_POOL_ID) > 0) {
            _claimApeCoin();
        }
        if (
            coinPool.pendingApeCoin() < amount_ &&
            _stakedApeCoin(ApeStakingLib.APE_COIN_POOL_ID) > (amount_ - coinPool.pendingApeCoin())
        ) {
            _unstakeApeCoin(amount_ - coinPool.pendingApeCoin());
        }
        coinPool.pullApeCoin(amount_);
    }

    function _stakeApeCoin(uint256 amount_) private {
        coinPool.pullApeCoin(amount_);
        apeCoinStaking.depositSelfApeCoin(amount_);
        apeCoinPoolStakedAmount += amount_;
    }

    function stakeApeCoin(uint256 amount_) external override onlyBot {
        _stakeApeCoin(amount_);
    }

    function _unstakeApeCoin(uint256 amount_) private {
        uint256 receivedApeCoin = apeCoin.balanceOf(address(this));
        apeCoinStaking.withdrawSelfApeCoin(amount_);
        receivedApeCoin = apeCoin.balanceOf(address(this)) - receivedApeCoin;
        apeCoinPoolStakedAmount -= amount_;

        if (receivedApeCoin > amount_) {
            receivedApeCoin -= _collectFee(receivedApeCoin - amount_);
        }
        coinPool.receiveApeCoin(receivedApeCoin);
    }

    function unstakeApeCoin(uint256 amount_) external override onlyCoinPoolOrBot {
        _unstakeApeCoin(amount_);
    }

    function _claimApeCoin() private {
        uint256 rewardsAmount = apeCoin.balanceOf(address(this));
        apeCoinStaking.claimSelfApeCoin();
        rewardsAmount = apeCoin.balanceOf(address(this)) - rewardsAmount;
        rewardsAmount -= _collectFee(rewardsAmount);
        coinPool.receiveApeCoin(rewardsAmount);
    }

    function claimApeCoin() external override onlyCoinPoolOrBot {
        _claimApeCoin();
    }

    function _stakeBayc(uint256[] memory tokenIds_) private {
        IApeCoinStaking.SingleNft[] memory nfts_ = new IApeCoinStaking.SingleNft[](tokenIds_.length);
        uint256 maxCap = apeCoinStaking.getCurrentTimeRange(ApeStakingLib.BAYC_POOL_ID).capPerPosition;
        uint256 tokenId_;
        uint256 apeCoinAmount = 0;
        for (uint256 i = 0; i < nfts_.length; i++) {
            tokenId_ = tokenIds_[i];
            nfts_[i] = IApeCoinStaking.SingleNft({tokenId: tokenId_.toUint32(), amount: maxCap.toUint224()});
            apeCoinAmount += maxCap;
            _stakedTokenIds[ApeStakingLib.BAYC_POOL_ID].add(tokenId_);
        }
        _prepareApeCoin(apeCoinAmount);
        nftVault.stakeBaycPool(nfts_);
    }

    function stakeBayc(uint256[] calldata tokenIds_) external override onlyBot {
        _stakeBayc(tokenIds_);
    }

    function _unstakeBayc(uint256[] memory tokenIds_) private {
        IApeCoinStaking.SingleNft[] memory nfts_ = new IApeCoinStaking.SingleNft[](tokenIds_.length);
        uint256 tokenId_;
        address nft_ = address(apeCoinStaking.bayc());

        for (uint256 i = 0; i < nfts_.length; i++) {
            tokenId_ = tokenIds_[i];
            nfts_[i] = IApeCoinStaking.SingleNft({
                tokenId: tokenId_.toUint32(),
                amount: apeCoinStaking.getNftPosition(nft_, tokenId_).stakedAmount.toUint224()
            });
            _stakedTokenIds[ApeStakingLib.BAYC_POOL_ID].remove(tokenId_);
        }
        uint256 receivedAmount = apeCoin.balanceOf(address(this));
        (uint256 principalAmount, uint256 rewardsAmount) = nftVault.unstakeBaycPool(nfts_, address(this));
        receivedAmount = apeCoin.balanceOf(address(this)) - receivedAmount;
        require(receivedAmount == (principalAmount + rewardsAmount), "BendStakeManager: unstake bayc error");

        coinPool.receiveApeCoin(principalAmount);
        rewardsAmount -= _collectFee(rewardsAmount);
        _distributeRewards(nft_, rewardsAmount);
    }

    function unstakeBayc(uint256[] calldata tokenIds_) external override onlyCoinPoolOrBot {
        _unstakeBayc(tokenIds_);
    }

    function _claimBayc(uint256[] memory tokenIds_) private {
        uint256 rewardsAmount = apeCoin.balanceOf(address(this));
        address nft_ = address(apeCoinStaking.bayc());
        nftVault.claimBaycPool(tokenIds_, address(this));
        rewardsAmount = apeCoin.balanceOf(address(this)) - rewardsAmount;
        rewardsAmount -= _collectFee(rewardsAmount);
        _distributeRewards(nft_, rewardsAmount);
    }

    function claimBayc(uint256[] calldata tokenIds_) external override onlyCoinPoolOrBot {
        _claimBayc(tokenIds_);
    }

    function _stakeMayc(uint256[] memory tokenIds_) private {
        IApeCoinStaking.SingleNft[] memory nfts_ = new IApeCoinStaking.SingleNft[](tokenIds_.length);
        uint256 maxCap = apeCoinStaking.getCurrentTimeRange(ApeStakingLib.MAYC_POOL_ID).capPerPosition;
        uint256 tokenId_;
        uint256 apeCoinAmount = 0;
        for (uint256 i = 0; i < nfts_.length; i++) {
            tokenId_ = tokenIds_[i];
            nfts_[i] = IApeCoinStaking.SingleNft({tokenId: tokenId_.toUint32(), amount: maxCap.toUint224()});
            apeCoinAmount += maxCap;
            _stakedTokenIds[ApeStakingLib.MAYC_POOL_ID].add(tokenId_);
        }
        _prepareApeCoin(apeCoinAmount);
        nftVault.stakeMaycPool(nfts_);
    }

    function stakeMayc(uint256[] calldata tokenIds_) external override onlyBot {
        _stakeMayc(tokenIds_);
    }

    function _unstakeMayc(uint256[] memory tokenIds_) private {
        IApeCoinStaking.SingleNft[] memory nfts_ = new IApeCoinStaking.SingleNft[](tokenIds_.length);
        uint256 tokenId_;
        address nft_ = address(apeCoinStaking.mayc());

        for (uint256 i = 0; i < nfts_.length; i++) {
            tokenId_ = tokenIds_[i];
            nfts_[i] = IApeCoinStaking.SingleNft({
                tokenId: tokenId_.toUint32(),
                amount: apeCoinStaking.getNftPosition(nft_, tokenId_).stakedAmount.toUint224()
            });
            _stakedTokenIds[ApeStakingLib.MAYC_POOL_ID].remove(tokenId_);
        }
        uint256 receivedAmount = apeCoin.balanceOf(address(this));
        (uint256 principalAmount, uint256 rewardsAmount) = nftVault.unstakeMaycPool(nfts_, address(this));
        receivedAmount = apeCoin.balanceOf(address(this)) - receivedAmount;
        require(receivedAmount == (principalAmount + rewardsAmount), "BendStakeManager: unstake mayc error");

        // return principao to ape coin pool
        coinPool.receiveApeCoin(principalAmount);
        rewardsAmount -= _collectFee(rewardsAmount);
        // distribute mayc rewardsAmount
        _distributeRewards(nft_, rewardsAmount);
    }

    function unstakeMayc(uint256[] calldata tokenIds_) external override onlyCoinPoolOrBot {
        _unstakeMayc(tokenIds_);
    }

    function _claimMayc(uint256[] memory tokenIds_) private {
        uint256 rewardsAmount = apeCoin.balanceOf(address(this));
        address nft_ = address(apeCoinStaking.mayc());
        nftVault.claimMaycPool(tokenIds_, address(this));
        rewardsAmount = apeCoin.balanceOf(address(this)) - rewardsAmount;
        rewardsAmount -= _collectFee(rewardsAmount);
        _distributeRewards(nft_, rewardsAmount);
    }

    function claimMayc(uint256[] calldata tokenIds_) external override onlyCoinPoolOrBot {
        _claimMayc(tokenIds_);
    }

    function _stakeBakc(IApeCoinStaking.PairNft[] memory baycPairs_, IApeCoinStaking.PairNft[] memory maycPairs_)
        private
    {
        IApeCoinStaking.PairNftDepositWithAmount[]
            memory baycPairsWithAmount_ = new IApeCoinStaking.PairNftDepositWithAmount[](baycPairs_.length);

        IApeCoinStaking.PairNftDepositWithAmount[]
            memory maycPairsWithAmount_ = new IApeCoinStaking.PairNftDepositWithAmount[](maycPairs_.length);

        uint256 maxCap = apeCoinStaking.getCurrentTimeRange(ApeStakingLib.BAKC_POOL_ID).capPerPosition;
        uint256 apeCoinAmount = 0;
        IApeCoinStaking.PairNft memory pair_;
        for (uint256 i = 0; i < baycPairsWithAmount_.length; i++) {
            pair_ = baycPairs_[i];
            baycPairsWithAmount_[i] = IApeCoinStaking.PairNftDepositWithAmount({
                mainTokenId: pair_.mainTokenId.toUint32(),
                bakcTokenId: pair_.bakcTokenId.toUint32(),
                amount: maxCap.toUint184()
            });
            apeCoinAmount += maxCap;
            _stakedTokenIds[ApeStakingLib.BAKC_POOL_ID].add(pair_.bakcTokenId);
        }
        for (uint256 i = 0; i < maycPairsWithAmount_.length; i++) {
            pair_ = maycPairs_[i];
            maycPairsWithAmount_[i] = IApeCoinStaking.PairNftDepositWithAmount({
                mainTokenId: pair_.mainTokenId.toUint32(),
                bakcTokenId: pair_.bakcTokenId.toUint32(),
                amount: maxCap.toUint184()
            });
            apeCoinAmount += maxCap;
            _stakedTokenIds[ApeStakingLib.BAKC_POOL_ID].add(pair_.bakcTokenId);
        }

        _prepareApeCoin(apeCoinAmount);

        nftVault.stakeBakcPool(baycPairsWithAmount_, maycPairsWithAmount_);
    }

    function stakeBakc(IApeCoinStaking.PairNft[] calldata baycPairs_, IApeCoinStaking.PairNft[] calldata maycPairs_)
        external
        override
        onlyBot
    {
        _stakeBakc(baycPairs_, maycPairs_);
    }

    function _unstakeBakc(IApeCoinStaking.PairNft[] memory baycPairs_, IApeCoinStaking.PairNft[] memory maycPairs_)
        private
    {
        address nft_ = address(apeCoinStaking.bakc());
        IApeCoinStaking.PairNftWithdrawWithAmount[]
            memory baycPairsWithAmount_ = new IApeCoinStaking.PairNftWithdrawWithAmount[](baycPairs_.length);

        IApeCoinStaking.PairNftWithdrawWithAmount[]
            memory maycPairsWithAmount_ = new IApeCoinStaking.PairNftWithdrawWithAmount[](maycPairs_.length);

        IApeCoinStaking.PairNft memory pair_;
        for (uint256 i = 0; i < baycPairsWithAmount_.length; i++) {
            pair_ = baycPairs_[i];
            baycPairsWithAmount_[i] = IApeCoinStaking.PairNftWithdrawWithAmount({
                mainTokenId: pair_.mainTokenId.toUint32(),
                bakcTokenId: pair_.bakcTokenId.toUint32(),
                amount: 0,
                isUncommit: true
            });
            _stakedTokenIds[ApeStakingLib.BAKC_POOL_ID].remove(pair_.bakcTokenId);
        }
        for (uint256 i = 0; i < maycPairsWithAmount_.length; i++) {
            pair_ = maycPairs_[i];
            maycPairsWithAmount_[i] = IApeCoinStaking.PairNftWithdrawWithAmount({
                mainTokenId: pair_.mainTokenId.toUint32(),
                bakcTokenId: pair_.bakcTokenId.toUint32(),
                amount: 0,
                isUncommit: true
            });
            _stakedTokenIds[ApeStakingLib.BAKC_POOL_ID].remove(pair_.bakcTokenId);
        }
        uint256 receivedAmount = apeCoin.balanceOf(address(this));
        (uint256 principalAmount, uint256 rewardsAmount) = nftVault.unstakeBakcPool(
            baycPairsWithAmount_,
            maycPairsWithAmount_,
            address(this)
        );
        receivedAmount = apeCoin.balanceOf(address(this)) - receivedAmount;
        require(receivedAmount == (principalAmount + rewardsAmount), "BendStakeManager: unstake bakc error");

        // return principao to ape coin pool
        coinPool.receiveApeCoin(principalAmount);
        rewardsAmount -= _collectFee(rewardsAmount);
        // distribute bakc rewardsAmount
        _distributeRewards(nft_, rewardsAmount);
    }

    function unstakeBakc(IApeCoinStaking.PairNft[] calldata baycPairs_, IApeCoinStaking.PairNft[] calldata maycPairs_)
        external
        override
        onlyCoinPoolOrBot
    {
        _unstakeBakc(baycPairs_, maycPairs_);
    }

    function _claimBakc(IApeCoinStaking.PairNft[] memory baycPairs_, IApeCoinStaking.PairNft[] memory maycPairs_)
        private
    {
        uint256 rewardsAmount = apeCoin.balanceOf(address(this));
        address nft_ = address(apeCoinStaking.bakc());
        nftVault.claimBakcPool(baycPairs_, maycPairs_, address(this));
        rewardsAmount = apeCoin.balanceOf(address(this)) - rewardsAmount;
        rewardsAmount -= _collectFee(rewardsAmount);
        _distributeRewards(nft_, rewardsAmount);
    }

    function claimBakc(IApeCoinStaking.PairNft[] calldata baycPairs_, IApeCoinStaking.PairNft[] calldata maycPairs_)
        external
        override
        onlyCoinPoolOrBot
    {
        _claimBakc(baycPairs_, maycPairs_);
    }

    function _withdrawRefund(address nft_) internal {
        INftVault.Refund memory refund = nftVault.refundOf(address(apeCoinStaking.bayc()), address(this));

        if (refund.principal > 0) {
            coinPool.receiveApeCoin(refund.principal);
        }
        if (refund.reward > 0) {
            uint256 rewardsAmount = refund.reward - _collectFee(refund.reward);
            _distributeRewards(nft_, rewardsAmount);
        }
    }

    function _distributeRewards(address nft_, uint256 rewardsAmount) internal {
        //TODO: static call
        uint256 nftPoolRewards = rewardsStrategies[nft_].calculateNftRewards(rewardsAmount);

        uint256 apeCoinPoolRewards = rewardsAmount - nftPoolRewards;

        coinPool.receiveApeCoin(apeCoinPoolRewards);

        nftPool.receiveApeCoin(nft_, nftPoolRewards);
    }

    function _withdrawTotalRefund() private {
        _withdrawRefund(address(apeCoinStaking.bayc()));
        _withdrawRefund(address(apeCoinStaking.mayc()));
        _withdrawRefund(address(apeCoinStaking.bakc()));
    }

    function withdrawTotalRefund() external override onlyCoinPoolOrBot {
        _withdrawTotalRefund();
    }

    function withdrawRefund(address nft_) external override onlyCoinPoolOrBot onlyApe(nft_) {
        _withdrawRefund(nft_);
    }

    function _refundOf(address nft_) internal view returns (uint256 principal, uint256 reward) {
        INftVault.Refund memory refund = nftVault.refundOf(nft_, address(this));
        principal = refund.principal;
        reward = refund.reward;
    }

    function refundOf(address nft_) external view onlyApe(nft_) returns (uint256) {
        (uint256 pricipal, uint256 reward) = _refundOf(nft_);
        if (fee > 0) {
            return pricipal += reward.mulDiv(PERCENTAGE_FACTOR - fee, PERCENTAGE_FACTOR, MathUpgradeable.Rounding.Up);
        } else {
            return pricipal += reward;
        }
    }

    function _totalRefund() private view returns (uint256 principal, uint256 reward) {
        INftVault.Refund memory refund_ = nftVault.refundOf(address(apeCoinStaking.bayc()), address(this));
        principal += refund_.principal;
        reward += refund_.reward;
        refund_ = nftVault.refundOf(address(apeCoinStaking.mayc()), address(this));
        principal += refund_.principal;
        reward += refund_.reward;
        refund_ = nftVault.refundOf(address(apeCoinStaking.bakc()), address(this));
        principal += refund_.principal;
        reward += refund_.reward;
    }

    function totalRefund() external view override returns (uint256 refunds) {
        (uint256 pricipal, uint256 reward) = _totalRefund();
        if (fee > 0) {
            return pricipal += reward.mulDiv(PERCENTAGE_FACTOR - fee, PERCENTAGE_FACTOR, MathUpgradeable.Rounding.Up);
        } else {
            return pricipal += reward;
        }
    }

    function compound(CompoundArgs calldata args_) external override onlyBot {
        // withdraw refunds which caused by users active burn the staked NFT
        address nft_ = address(apeCoinStaking.bayc());
        (uint256 principal, ) = _refundOf(address(nft_));
        if (principal > 0) {
            _withdrawRefund(nft_);
        }
        nft_ = address(apeCoinStaking.mayc());
        (principal, ) = _refundOf(address(nft_));
        if (principal > 0) {
            _withdrawRefund(nft_);
        }
        nft_ = address(apeCoinStaking.bakc());
        (principal, ) = _refundOf(address(nft_));
        if (principal > 0) {
            _withdrawRefund(nft_);
        }

        // claim rewards from coin pool
        if (args_.claimCoinPool) {
            _claimApeCoin();
        }

        // claim rewards from NFT pool
        if (args_.claim.bayc.length > 0) {
            _claimBayc(args_.claim.bayc);
        }
        if (args_.claim.mayc.length > 0) {
            _claimBayc(args_.claim.mayc);
        }
        if (args_.claim.baycPairs.length > 0 || args_.claim.maycPairs.length > 0) {
            _claimBakc(args_.claim.baycPairs, args_.claim.maycPairs);
        }

        // unstake some NFTs from NFT pool
        if (args_.unstake.bayc.length > 0) {
            _unstakeBayc(args_.unstake.bayc);
        }
        if (args_.unstake.mayc.length > 0) {
            _unstakeMayc(args_.unstake.mayc);
        }
        if (args_.unstake.baycPairs.length > 0 || args_.unstake.maycPairs.length > 0) {
            _unstakeBakc(args_.unstake.baycPairs, args_.unstake.maycPairs);
        }

        // stake some NFTs to NFT pool
        if (args_.stake.bayc.length > 0) {
            _stakeBayc(args_.stake.bayc);
        }
        if (args_.stake.mayc.length > 0) {
            _stakeMayc(args_.stake.mayc);
        }
        if (args_.stake.baycPairs.length > 0 || args_.stake.maycPairs.length > 0) {
            _stakeBakc(args_.stake.baycPairs, args_.stake.maycPairs);
        }

        // stake ape coin to coin pool
        if (coinPool.pendingApeCoin() >= args_.coinStakeThreshold) {
            _stakeApeCoin(coinPool.pendingApeCoin());
        }

        // transfer fee to recipient
        if (pendingFeeAmount > MAX_PENDING_FEE && feeRecipient != address(0)) {
            apeCoin.safeTransfer(feeRecipient, pendingFeeAmount);
            pendingFeeAmount = 0;
        }
    }
}
