// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.18;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {INftVault, IApeCoinStaking, IERC721Receiver} from "../interfaces/INftVault.sol";
import {IDelegationRegistry} from "../interfaces/IDelegationRegistry.sol";

import {ApeStakingLib} from "../libraries/ApeStakingLib.sol";

contract NftVault is INftVault {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for uint248;
    using SafeCast for int256;
    using ApeStakingLib for IApeCoinStaking;

    struct NftStatus {
        address owner;
        address staker;
    }

    // nft address =>  nft tokenId => nftStatus
    mapping(address => mapping(uint256 => NftStatus)) private _nfts;
    // nft address => staker address => refund
    mapping(address => mapping(address => Refund)) private _refunds;
    // nft address => staker address => position
    mapping(address => mapping(address => Position)) private _positions;

    IApeCoinStaking public apeCoinStaking;
    IERC20 public apeCoin;
    address public bayc;
    address public mayc;
    address public bakc;
    IDelegationRegistry public delegationRegistry;

    modifier onlyApe(address nft_) {
        require(nft_ == bayc || nft_ == mayc || nft_ == bakc, "NftVault: not ape");
        _;
    }

    modifier onlyApeCaller() {
        require(msg.sender == bayc || msg.sender == mayc || msg.sender == bakc, "NftVault: caller not ape");
        _;
    }

    constructor(IApeCoinStaking apeCoinStaking_, IDelegationRegistry delegationRegistry_) {
        apeCoinStaking = apeCoinStaking_;
        delegationRegistry = delegationRegistry_;
        apeCoin = IERC20(apeCoinStaking.apeCoin());
        bayc = address(apeCoinStaking.bayc());
        mayc = address(apeCoinStaking.mayc());
        bakc = address(apeCoinStaking.bakc());
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external view override onlyApeCaller returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function stakerOf(address nft_, uint256 tokenId_) external view onlyApe(nft_) returns (address) {
        return _stakerOf(nft_, tokenId_);
    }

    function ownerOf(address nft_, uint256 tokenId_) external view onlyApe(nft_) returns (address) {
        return _ownerOf(nft_, tokenId_);
    }

    function _stakerOf(address nft_, uint256 tokenId_) internal view onlyApe(nft_) returns (address) {
        return _nfts[nft_][tokenId_].staker;
    }

    function _ownerOf(address nft_, uint256 tokenId_) internal view onlyApe(nft_) returns (address) {
        return _nfts[nft_][tokenId_].owner;
    }

    function refundOf(address nft_, address staker_) external view onlyApe(nft_) returns (Refund memory) {
        return _refunds[nft_][staker_];
    }

    function positionOf(address nft_, address staker_) external view onlyApe(nft_) returns (Position memory) {
        return _positions[nft_][staker_];
    }

    function pendingRewards(address nft_, address staker_) external view onlyApe(nft_) returns (uint256) {
        IApeCoinStaking.PoolWithoutTimeRange memory pool = apeCoinStaking.getNftPool(nft_);
        Position memory position = _positions[nft_][staker_];

        (uint256 rewardsSinceLastCalculated, ) = apeCoinStaking.getNftRewardsBy(
            nft_,
            pool.lastRewardedTimestampHour,
            ApeStakingLib.getPreviousTimestampHour()
        );
        uint256 accumulatedRewardsPerShare = pool.accumulatedRewardsPerShare;

        if (
            block.timestamp > pool.lastRewardedTimestampHour + ApeStakingLib.SECONDS_PER_HOUR && pool.stakedAmount != 0
        ) {
            accumulatedRewardsPerShare =
                accumulatedRewardsPerShare +
                (rewardsSinceLastCalculated * ApeStakingLib.APE_COIN_PRECISION) /
                pool.stakedAmount;
        }
        return
            ((position.stakedAmount * accumulatedRewardsPerShare).toInt256() - position.rewardsDebt).toUint256() /
            ApeStakingLib.APE_COIN_PRECISION;
    }

    function setDelegateCash(
        address delegate_,
        address nft_,
        uint256[] calldata tokenIds_,
        bool value_
    ) external override onlyApe(nft_) {
        uint256 tokenId_;
        for (uint256 i = 0; i < tokenIds_.length; i++) {
            tokenId_ = tokenIds_[i];
            require(msg.sender == _ownerOf(nft_, tokenId_), "nftVault: only owner can delegate");
            delegationRegistry.delegateForToken(delegate_, nft_, tokenId_, value_);
        }
    }

    function depositNFT(
        address nft_,
        uint256[] calldata tokenIds_,
        address staker_
    ) external override onlyApe(nft_) {
        IApeCoinStaking.Position memory position_;

        // transfer nft and set permission
        for (uint256 i = 0; i < tokenIds_.length; i++) {
            // block partially stake from official contract
            position_ = apeCoinStaking.getNftPosition(nft_, tokenIds_[i]);
            require(position_.stakedAmount == 0, "nftVault: nft already staked");
            IERC721(nft_).safeTransferFrom(msg.sender, address(this), tokenIds_[i]);
            _nfts[nft_][tokenIds_[i]] = NftStatus(msg.sender, staker_);
        }
    }

    struct RefundSinglePoolVars {
        uint256 totalPrincipal;
        uint256 totalReward;
        uint256 totalPairingPrincipal;
        uint256 totalPairingReward;
        address staker;
        uint256 poolId;
        uint256 singleNftIndex;
        uint256 singleNftSize;
        uint256 pairingNftIndex;
        uint256 pairingNftSize;
    }

    function _refundSinglePool(address nft_, uint256[] calldata tokenIds_) internal {
        require(nft_ == bayc || nft_ == mayc, "nftVault: not bayc or mayc");
        require(tokenIds_.length > 0, "nftVault: invalid tokenIds");
        RefundSinglePoolVars memory vars;

        vars.staker = _stakerOf(nft_, tokenIds_[0]);

        uint256 apeCoinBalance = apeCoin.balanceOf(address(this));
        uint256 tokenId;
        uint256 bakcTokenId;
        uint256 stakedAmount;

        IApeCoinStaking.SingleNft[] memory singleNftsContainer_ = new IApeCoinStaking.SingleNft[](tokenIds_.length);

        IApeCoinStaking.PairNftWithdrawWithAmount[]
            memory pairingNftsContainer_ = new IApeCoinStaking.PairNftWithdrawWithAmount[](tokenIds_.length);

        vars.poolId = ApeStakingLib.BAYC_POOL_ID;
        if (nft_ == mayc) {
            vars.poolId = ApeStakingLib.MAYC_POOL_ID;
        }

        for (uint256 i = 0; i < tokenIds_.length; i++) {
            tokenId = tokenIds_[i];
            require(msg.sender == _ownerOf(nft_, tokenId), "nftVault: caller must be nft owner");
            require(vars.staker == _stakerOf(nft_, tokenId), "nftVault: staker must be same");
            stakedAmount = apeCoinStaking.nftPosition(vars.poolId, tokenId).stakedAmount;

            // Still have ape coin staking in single pool
            if (stakedAmount > 0) {
                vars.totalPrincipal += stakedAmount;
                singleNftsContainer_[vars.singleNftIndex] = IApeCoinStaking.SingleNft({
                    tokenId: tokenId.toUint32(),
                    amount: stakedAmount.toUint224()
                });
                vars.singleNftIndex += 1;
                vars.singleNftSize += 1;
            }

            IApeCoinStaking.PairingStatus memory pairingStatus = apeCoinStaking.mainToBakc(vars.poolId, tokenId);
            bakcTokenId = pairingStatus.tokenId;
            stakedAmount = apeCoinStaking.nftPosition(ApeStakingLib.BAKC_POOL_ID, bakcTokenId).stakedAmount;

            //  Still have ape coin staking in pairing pool
            if (pairingStatus.isPaired && stakedAmount > 0) {
                vars.totalPairingPrincipal += stakedAmount;
                pairingNftsContainer_[vars.pairingNftIndex] = IApeCoinStaking.PairNftWithdrawWithAmount({
                    mainTokenId: tokenId.toUint32(),
                    bakcTokenId: bakcTokenId.toUint32(),
                    amount: stakedAmount.toUint184(),
                    isUncommit: true
                });
                vars.pairingNftIndex += 1;
                vars.pairingNftSize += 1;
            }
        }

        if (vars.singleNftSize > 0) {
            IApeCoinStaking.SingleNft[] memory singleNfts_ = new IApeCoinStaking.SingleNft[](vars.singleNftSize);
            for (uint256 i = 0; i < vars.singleNftSize; i++) {
                singleNfts_[i] = singleNftsContainer_[i];
            }
            if (nft_ == bayc) {
                apeCoinStaking.withdrawBAYC(singleNfts_, address(this));
            } else {
                apeCoinStaking.withdrawMAYC(singleNfts_, address(this));
            }
            vars.totalReward = apeCoin.balanceOf(address(this)) - apeCoinBalance - vars.totalPrincipal;
            // refund ape coin for single nft
            if (vars.staker != address(0)) {
                Refund storage _refund = _refunds[nft_][vars.staker];
                _refund.principal += vars.totalPrincipal;
                _refund.reward += vars.totalReward;

                // update bayc&mayc position and debt
                if (vars.totalReward > 0) {
                    _updateRewardsDebt(nft_, vars.staker, vars.totalReward);
                }
                _decreasePosition(nft_, vars.staker, vars.totalPrincipal);
            }
        }

        if (vars.pairingNftSize > 0) {
            IApeCoinStaking.PairNftWithdrawWithAmount[]
                memory pairingNfts_ = new IApeCoinStaking.PairNftWithdrawWithAmount[](vars.pairingNftSize);
            for (uint256 i = 0; i < vars.pairingNftSize; i++) {
                pairingNfts_[i] = pairingNftsContainer_[i];
            }
            apeCoinBalance = apeCoin.balanceOf(address(this));
            IApeCoinStaking.PairNftWithdrawWithAmount[] memory emptyNfts;

            if (nft_ == bayc) {
                apeCoinStaking.withdrawBAKC(pairingNfts_, emptyNfts);
            } else {
                apeCoinStaking.withdrawBAKC(emptyNfts, pairingNfts_);
            }
            vars.totalPairingReward = apeCoin.balanceOf(address(this)) - apeCoinBalance - vars.totalPairingPrincipal;

            // refund ape coin for paring nft
            Refund storage _refund = _refunds[bakc][vars.staker];
            _refund.principal += vars.totalPairingPrincipal;
            _refund.reward += vars.totalPairingReward;

            // update bakc position and debt
            if (vars.totalPairingReward > 0) {
                _updateRewardsDebt(bakc, vars.staker, vars.totalPairingReward);
            }
            _decreasePosition(bakc, vars.staker, vars.totalPairingPrincipal);
        }
    }

    struct RefundPairingPoolVars {
        uint256 totalPrincipal;
        uint256 totalReward;
        address staker;
        uint256 baycIndex;
        uint256 baycSize;
        uint256 maycIndex;
        uint256 maycSize;
    }

    function _refundPairingPool(uint256[] calldata tokenIds_) internal {
        require(tokenIds_.length > 0, "nftVault: invalid tokenIds");
        RefundPairingPoolVars memory vars;

        vars.staker = _stakerOf(bakc, tokenIds_[0]);
        uint256 apeCoinBalance = apeCoin.balanceOf(address(this));

        IApeCoinStaking.PairNftWithdrawWithAmount[]
            memory baycNftsContainer_ = new IApeCoinStaking.PairNftWithdrawWithAmount[](tokenIds_.length);

        IApeCoinStaking.PairNftWithdrawWithAmount[]
            memory maycNftsContainer_ = new IApeCoinStaking.PairNftWithdrawWithAmount[](tokenIds_.length);

        for (uint256 i = 0; i < tokenIds_.length; i++) {
            uint256 tokenId_ = tokenIds_[i];
            require(msg.sender == _ownerOf(bakc, tokenId_), "nftVault: caller must be nft owner");
            require(vars.staker == _stakerOf(bakc, tokenId_), "nftVault: staker must be same");

            uint256 stakedAmount = apeCoinStaking.nftPosition(ApeStakingLib.BAKC_POOL_ID, tokenId_).stakedAmount;
            if (stakedAmount > 0) {
                vars.totalPrincipal += stakedAmount;
                IApeCoinStaking.PairingStatus memory pBaycStatus = apeCoinStaking.bakcToMain(
                    tokenId_,
                    ApeStakingLib.BAYC_POOL_ID
                );
                IApeCoinStaking.PairingStatus memory pMaycStatus = apeCoinStaking.bakcToMain(
                    tokenId_,
                    ApeStakingLib.MAYC_POOL_ID
                );

                if (pBaycStatus.isPaired) {
                    baycNftsContainer_[vars.baycIndex] = IApeCoinStaking.PairNftWithdrawWithAmount({
                        mainTokenId: pBaycStatus.tokenId.toUint32(),
                        bakcTokenId: tokenId_.toUint32(),
                        amount: stakedAmount.toUint184(),
                        isUncommit: true
                    });
                    vars.baycIndex += 1;
                    vars.baycSize += 1;
                } else if (pMaycStatus.isPaired) {
                    maycNftsContainer_[vars.maycIndex] = IApeCoinStaking.PairNftWithdrawWithAmount({
                        mainTokenId: pMaycStatus.tokenId.toUint32(),
                        bakcTokenId: tokenId_.toUint32(),
                        amount: stakedAmount.toUint184(),
                        isUncommit: true
                    });
                    vars.maycIndex += 1;
                    vars.maycSize += 1;
                }
            }
        }

        if (vars.baycSize > 0 || vars.maycSize > 0) {
            IApeCoinStaking.PairNftWithdrawWithAmount[]
                memory baycNfts_ = new IApeCoinStaking.PairNftWithdrawWithAmount[](vars.baycSize);
            IApeCoinStaking.PairNftWithdrawWithAmount[]
                memory maycNfts_ = new IApeCoinStaking.PairNftWithdrawWithAmount[](vars.maycSize);
            for (uint256 i = 0; i < vars.baycSize; i++) {
                baycNfts_[i] = baycNftsContainer_[i];
            }
            for (uint256 i = 0; i < vars.maycSize; i++) {
                maycNfts_[i] = maycNftsContainer_[i];
            }
            apeCoinStaking.withdrawBAKC(baycNfts_, maycNfts_);
            vars.totalReward = apeCoin.balanceOf(address(this)) - apeCoinBalance - vars.totalPrincipal;
            // refund ape coin for bakc
            if (vars.staker != address(0)) {
                Refund storage _refund = _refunds[bakc][vars.staker];
                _refund.principal += vars.totalPrincipal;
                _refund.reward += vars.totalReward;

                // update bakc position and debt
                if (vars.totalReward > 0) {
                    _updateRewardsDebt(bakc, vars.staker, vars.totalReward);
                }
                _decreasePosition(bakc, vars.staker, vars.totalReward);
            }
        }
    }

    function withdrawNFT(address nft_, uint256[] calldata tokenIds_) external override onlyApe(nft_) {
        require(tokenIds_.length > 0, "nftVault: invalid tokenIds");
        if (nft_ == bayc || nft_ == mayc) {
            _refundSinglePool(nft_, tokenIds_);
        } else if (nft_ == bakc) {
            _refundPairingPool(tokenIds_);
        }
        // transfer nft to sender
        for (uint256 i = 0; i < tokenIds_.length; i++) {
            // transfer nft
            IERC721(nft_).safeTransferFrom(address(this), msg.sender, tokenIds_[i]);
            delete _nfts[nft_][tokenIds_[i]];
        }
    }

    function withdrawRefunds(address nft_) external override onlyApe(nft_) {
        Refund memory _refund = _refunds[nft_][msg.sender];
        uint256 amount = _refund.principal + _refund.reward;
        delete _refunds[nft_][msg.sender];
        apeCoin.safeTransfer(msg.sender, amount);
    }

    function _increasePosition(
        address nft_,
        address staker_,
        uint256 stakedAmount_
    ) private {
        Position storage position_ = _positions[nft_][staker_];
        position_.stakedAmount += stakedAmount_;
        position_.rewardsDebt += (stakedAmount_ * apeCoinStaking.getNftPool(nft_).accumulatedRewardsPerShare)
            .toInt256();
    }

    function _decreasePosition(
        address nft_,
        address staker_,
        uint256 stakedAmount_
    ) private {
        Position storage position_ = _positions[nft_][staker_];
        position_.stakedAmount -= stakedAmount_;
        position_.rewardsDebt -= (stakedAmount_ * apeCoinStaking.getNftPool(nft_).accumulatedRewardsPerShare)
            .toInt256();
    }

    function _updateRewardsDebt(
        address nft_,
        address staker_,
        uint256 claimedRewardsAmount_
    ) private {
        Position storage position_ = _positions[nft_][staker_];
        position_.rewardsDebt += (claimedRewardsAmount_).toInt256();
    }

    function stakeBaycPool(IApeCoinStaking.SingleNft[] calldata nfts_) external override {
        uint256 totalStakedAmount = 0;
        IApeCoinStaking.SingleNft memory singleNft_;
        for (uint256 i = 0; i < nfts_.length; i++) {
            singleNft_ = nfts_[i];
            require(msg.sender == _stakerOf(bayc, singleNft_.tokenId), "nftVault: caller must be bayc staker");
            totalStakedAmount += singleNft_.amount;
        }
        apeCoin.safeTransferFrom(msg.sender, address(this), totalStakedAmount);
        apeCoinStaking.depositBAYC(nfts_);

        _increasePosition(bayc, msg.sender, totalStakedAmount);
    }

    function stakeMaycPool(IApeCoinStaking.SingleNft[] calldata nfts_) external override {
        uint256 totalApeCoinAmount = 0;
        IApeCoinStaking.SingleNft memory singleNft_;
        for (uint256 i = 0; i < nfts_.length; i++) {
            singleNft_ = nfts_[i];
            require(msg.sender == _stakerOf(mayc, singleNft_.tokenId), "nftVault: caller must be mayc staker");
            totalApeCoinAmount += singleNft_.amount;
        }
        apeCoin.safeTransferFrom(msg.sender, address(this), totalApeCoinAmount);
        apeCoinStaking.depositMAYC(nfts_);
        _increasePosition(mayc, msg.sender, totalApeCoinAmount);
    }

    function stakeBakcPool(
        IApeCoinStaking.PairNftDepositWithAmount[] calldata baycPairs_,
        IApeCoinStaking.PairNftDepositWithAmount[] calldata maycPairs_
    ) external override {
        uint256 totalStakedAmount = 0;
        IApeCoinStaking.PairNftDepositWithAmount memory pair;
        for (uint256 i = 0; i < baycPairs_.length; i++) {
            pair = baycPairs_[i];
            require(
                msg.sender == _stakerOf(bayc, pair.mainTokenId) && msg.sender == _stakerOf(bakc, pair.bakcTokenId),
                "nftVault: caller must be nft staker"
            );
            totalStakedAmount += pair.amount;
        }

        for (uint256 i = 0; i < maycPairs_.length; i++) {
            pair = maycPairs_[i];
            require(
                msg.sender == _stakerOf(mayc, pair.mainTokenId) && msg.sender == _stakerOf(bakc, pair.bakcTokenId),
                "nftVault: caller must be nft staker"
            );
            totalStakedAmount += pair.amount;
        }
        apeCoin.safeTransferFrom(msg.sender, address(this), totalStakedAmount);
        apeCoinStaking.depositBAKC(baycPairs_, maycPairs_);

        _increasePosition(bakc, msg.sender, totalStakedAmount);
    }

    function unstakeBaycPool(IApeCoinStaking.SingleNft[] calldata nfts_, address recipient_)
        external
        override
        returns (uint256 principal, uint256 rewards)
    {
        address nft_ = bayc;
        IApeCoinStaking.SingleNft memory singleNft_;
        for (uint256 i = 0; i < nfts_.length; i++) {
            singleNft_ = nfts_[i];
            require(msg.sender == _stakerOf(nft_, singleNft_.tokenId), "nftVault: caller must be nft staker");
            principal += singleNft_.amount;
        }
        rewards = apeCoin.balanceOf(recipient_);

        apeCoinStaking.withdrawBAYC(nfts_, recipient_);

        rewards = apeCoin.balanceOf(recipient_) - rewards - principal;
        if (rewards > 0) {
            _updateRewardsDebt(nft_, msg.sender, rewards);
        }

        _decreasePosition(nft_, msg.sender, principal);
    }

    function unstakeMaycPool(IApeCoinStaking.SingleNft[] calldata nfts_, address recipient_)
        external
        override
        returns (uint256 principal, uint256 rewards)
    {
        address nft_ = mayc;
        IApeCoinStaking.SingleNft memory singleNft_;
        for (uint256 i = 0; i < nfts_.length; i++) {
            singleNft_ = nfts_[i];
            require(msg.sender == _stakerOf(nft_, singleNft_.tokenId), "nftVault: caller must be nft staker");
            principal += singleNft_.amount;
        }
        rewards = apeCoin.balanceOf(recipient_);

        apeCoinStaking.withdrawMAYC(nfts_, recipient_);

        rewards = apeCoin.balanceOf(recipient_) - rewards - principal;
        if (rewards > 0) {
            _updateRewardsDebt(nft_, msg.sender, rewards);
        }

        _decreasePosition(nft_, msg.sender, principal);
    }

    function unstakeBakcPool(
        IApeCoinStaking.PairNftWithdrawWithAmount[] calldata baycPairs_,
        IApeCoinStaking.PairNftWithdrawWithAmount[] calldata maycPairs_,
        address recipient_
    ) external override returns (uint256 principal, uint256 rewards) {
        address nft_ = bakc;
        IApeCoinStaking.Position memory position_;
        IApeCoinStaking.PairNftWithdrawWithAmount memory pair;
        for (uint256 i = 0; i < baycPairs_.length; i++) {
            pair = baycPairs_[i];
            require(
                msg.sender == _stakerOf(bayc, pair.mainTokenId) && msg.sender == _stakerOf(nft_, pair.bakcTokenId),
                "nftVault: caller must be nft staker"
            );
            position_ = apeCoinStaking.getNftPosition(nft_, pair.bakcTokenId);
            principal += (pair.isUncommit ? position_.stakedAmount : pair.amount);
        }

        for (uint256 i = 0; i < maycPairs_.length; i++) {
            pair = maycPairs_[i];
            require(
                msg.sender == _stakerOf(mayc, pair.mainTokenId) && msg.sender == _stakerOf(nft_, pair.bakcTokenId),
                "nftVault: caller must be nft staker"
            );
            position_ = apeCoinStaking.getNftPosition(nft_, pair.bakcTokenId);
            principal += (pair.isUncommit ? position_.stakedAmount : pair.amount);
        }
        rewards = apeCoin.balanceOf(address(this));
        apeCoinStaking.withdrawBAKC(baycPairs_, maycPairs_);
        rewards = apeCoin.balanceOf(address(this)) - rewards - principal;
        if (rewards > 0) {
            _updateRewardsDebt(nft_, msg.sender, rewards);
        }
        _decreasePosition(nft_, msg.sender, principal);

        apeCoin.safeTransfer(recipient_, principal + rewards);
    }

    function claimBaycPool(uint256[] calldata tokenIds_, address recipient_)
        external
        override
        returns (uint256 rewards)
    {
        address nft_ = bayc;
        for (uint256 i = 0; i < tokenIds_.length; i++) {
            require(msg.sender == _stakerOf(nft_, tokenIds_[i]), "nftVault: caller must be nft staker");
        }
        rewards = apeCoin.balanceOf(address(recipient_));
        apeCoinStaking.claimBAYC(tokenIds_, recipient_);
        rewards = apeCoin.balanceOf(recipient_) - rewards;
        if (rewards > 0) {
            _updateRewardsDebt(nft_, msg.sender, rewards);
        }
    }

    function claimMaycPool(uint256[] calldata tokenIds_, address recipient_)
        external
        override
        returns (uint256 rewards)
    {
        address nft_ = mayc;
        for (uint256 i = 0; i < tokenIds_.length; i++) {
            require(msg.sender == _stakerOf(nft_, tokenIds_[i]), "nftVault: caller must be nft staker");
        }
        rewards = apeCoin.balanceOf(address(recipient_));
        apeCoinStaking.claimMAYC(tokenIds_, recipient_);
        rewards = apeCoin.balanceOf(recipient_) - rewards;
        if (rewards > 0) {
            _updateRewardsDebt(nft_, msg.sender, rewards);
        }
    }

    function claimBakcPool(
        IApeCoinStaking.PairNft[] calldata baycPairs_,
        IApeCoinStaking.PairNft[] calldata maycPairs_,
        address recipient_
    ) external override returns (uint256 rewards) {
        address nft_ = bakc;
        IApeCoinStaking.PairNft memory pair;
        for (uint256 i = 0; i < baycPairs_.length; i++) {
            pair = baycPairs_[i];
            require(
                msg.sender == _stakerOf(bayc, pair.mainTokenId) && msg.sender == _stakerOf(nft_, pair.bakcTokenId),
                "nftVault: caller must be nft staker"
            );
        }

        for (uint256 i = 0; i < maycPairs_.length; i++) {
            pair = maycPairs_[i];
            require(
                msg.sender == _stakerOf(mayc, pair.mainTokenId) && msg.sender == _stakerOf(bakc, pair.bakcTokenId),
                "nftVault: caller must be nft staker"
            );
        }
        rewards = apeCoin.balanceOf(address(recipient_));
        apeCoinStaking.claimBAKC(baycPairs_, maycPairs_, recipient_);
        rewards = apeCoin.balanceOf(recipient_) - rewards;
        if (rewards > 0) {
            _updateRewardsDebt(nft_, msg.sender, rewards);
        }
    }
}
