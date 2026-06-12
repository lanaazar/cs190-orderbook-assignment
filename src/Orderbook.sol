// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IOrderbook} from "./IOrderbook.sol";
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

contract Orderbook is IOrderbook {
    uint256 internal constant ONE = 1e18;

    IERC20 public immutable baseToken;
    IERC20 public immutable quoteToken;

    struct Order {
        uint256 id;
        address maker;
        Side side;
        uint256 price;
        uint256 amount;
    }

    uint256 public nextOrderId = 1;

    Order[] internal bids;
    Order[] internal asks;

    event OrderPlaced(
        uint256 indexed orderId,
        address indexed maker,
        Side side,
        uint256 price,
        uint256 amount
    );

    event OrderFilled(
        uint256 indexed orderId,
        address indexed taker,
        uint256 fillAmount,
        uint256 fillPrice
    );

    event OrderCleared();

    constructor(address _baseToken, address _quoteToken) {
        require(_baseToken != address(0), "baseToken=0");
        require(_quoteToken != address(0), "quoteToken=0");
        require(_baseToken != _quoteToken, "base==quote");

        baseToken = IERC20(_baseToken);
        quoteToken = IERC20(_quoteToken);
    }

    function getBaseToken() external view returns (address) {
        return address(baseToken);
    }

    function getQuoteToken() external view returns (address) {
        return address(quoteToken);
    }

    function placeLimitOrder(Side side, uint256 price, uint256 amount) external returns (uint256) {
        require(price > 0, "price=0");
        require(amount > 0, "amount=0");

        uint256 orderId = nextOrderId;
        nextOrderId++;

        if (side == Side.BUY) {
            uint256 quoteAmount = _quoteAmount(amount, price);
            require(quoteToken.transferFrom(msg.sender, address(this), quoteAmount), "quote transfer failed");

            bids.push(Order({
                id: orderId,
                maker: msg.sender,
                side: side,
                price: price,
                amount: amount
            }));
        } else {
            require(baseToken.transferFrom(msg.sender, address(this), amount), "base transfer failed");

            asks.push(Order({
                id: orderId,
                maker: msg.sender,
                side: side,
                price: price,
                amount: amount
            }));
        }

        emit OrderPlaced(orderId, msg.sender, side, price, amount);
        return orderId;
    }

    function placeMarketOrder(Side side, uint256 amount) external {
        require(amount > 0, "amount=0");
        if (side == Side.BUY) {
            _fillAsks(amount);
        } else {
            _fillBids(amount);
        }
    }

    function clear() external {
        for (uint256 i = 0; i < bids.length; i++) {
            uint256 refund = _quoteAmount(bids[i].amount, bids[i].price);
            require(quoteToken.transfer(bids[i].maker, refund), "quote refund failed");
        }

        for (uint256 i = 0; i < asks.length; i++) {
            require(baseToken.transfer(asks[i].maker, asks[i].amount), "base refund failed");
        }

        delete bids;
        delete asks;

        emit OrderCleared();
    }

    function getBidsCount() external view returns (uint256) {
        return bids.length;
    }

    function getAsksCount() external view returns (uint256) {
        return asks.length;
    }

    function getMidPrice() external view returns (uint256) {
        require(bids.length > 0, "no bids");
        require(asks.length > 0, "no asks");

        return (_bestBidPrice() + _bestAskPrice())/2;
    }

    function _fillAsks(uint256 amount) internal {
        uint256 remaining = amount;

        while (remaining > 0 && asks.length > 0) {
            uint256 index = _bestAskIndex();
            Order storage ask = asks[index];

            uint256 fillAmount = remaining < ask.amount ? remaining : ask.amount;
            uint256 quoteAmount = _quoteAmount(fillAmount, ask.price);

            require(quoteToken.transferFrom(msg.sender, ask.maker, quoteAmount), "quote payment failed");
            require(baseToken.transfer(msg.sender, fillAmount), "base payout failed");

            ask.amount -= fillAmount;
            remaining -= fillAmount;

            emit OrderFilled(ask.id, msg.sender, fillAmount, ask.price);

            if (ask.amount == 0) {
                _removeAsk(index);
            }
        }
    }

    function _fillBids(uint256 amount) internal {
        uint256 remaining = amount;

        while (remaining > 0 && bids.length > 0) {
            uint256 index = _bestBidIndex();
            Order storage bid = bids[index];

            uint256 fillAmount = remaining < bid.amount ? remaining : bid.amount;
            uint256 quoteAmount = _quoteAmount(fillAmount, bid.price);

            require(baseToken.transferFrom(msg.sender, bid.maker, fillAmount), "base payment failed");
            require(quoteToken.transfer(msg.sender, quoteAmount), "quote payout failed");

            bid.amount -= fillAmount;
            remaining -= fillAmount;

            emit OrderFilled(bid.id, msg.sender, fillAmount, bid.price);

            if (bid.amount == 0) {
                _removeBid(index);
            }
        }
    }

    function _bestAskIndex() internal view returns (uint256) {
        uint256 best = 0;

        for (uint256 i = 1; i < asks.length; i++) {
            if (asks[i].price < asks[best].price) {
                best = i;
            }
        }

        return best;
    }

    function _bestBidIndex() internal view returns (uint256) {
        uint256 best = 0;

        for (uint256 i = 1; i < bids.length; i++) {
            if (bids[i].price > bids[best].price) {
                best = i;
            }
        }

        return best;
    }

    function _bestAskPrice() internal view returns (uint256) {
        return asks[_bestAskIndex()].price;
    }

    function _bestBidPrice() internal view returns (uint256) {
        return bids[_bestBidIndex()].price;
    }

    function _removeAsk(uint256 index) internal {
        asks[index] = asks[asks.length - 1];
        asks.pop();
    }

    function _removeBid(uint256 index) internal {
        bids[index] = bids[bids.length - 1];
        bids.pop();
    }

    function _quoteAmount(uint256 amount, uint256 price) internal pure returns (uint256) {
        return amount * price/ONE;
    }
}

