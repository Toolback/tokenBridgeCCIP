// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "./CCIPReceiver.sol";
import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title - Base exemple using chainlink CCIP Arbitrary Message for token bridge.
contract TokenBridge is CCIPReceiver, OwnerIsCreator {
  using SafeERC20 for IERC20;

  // Custom errors to provide more descriptive revert messages.
  error NotEnoughBalanceForFees(uint256 currentBalance, uint256 calculatedFees); // Used to make sure sender has sent enough for fees.
  error NothingToWithdraw(); // Used when trying to withdraw erc20 locked tokens but there's nothing to withdraw.
  error FailedToWithdrawNative(address owner, address target, uint256 value); // Used when the withdrawal of Native Token fails.
  error DestinationChainNotAllowlisted(uint64 destinationChainSelector); // Used when the destination chain has not been allowlisted by the contract owner.
  error SourceChainNotAllowlisted(uint64 sourceChainSelector); // Used when the source chain has not been allowlisted by the contract owner.
  error RoutePaused(uint64 destinationChainSelector); // Used when the route between two chains has been paused by the contract owner.

  // Event emitted when tokens are sent to another chain.
  event TransferInit(
      bytes32 indexed messageId, // The unique ID of the CCIP message.
      uint64 indexed destinationChainSelector, // The chain selector of the destination chain.
      address receiver, // The address of the receiver contract on the destination chain.
      address recipient, // The address of the tokens recipient .
      uint256 tokenAmount, // the amount of token to send across network
      uint256 fees // The fees paid for sending the CCIP message.
  );
  // Event emitted when tokens are received from another chain.
  event TransferCompleted(
      bytes32 indexed messageId, // The unique ID of the CCIP message.
      uint64 indexed sourceChainSelector, // The chain selector of the source chain.
      address sender, // The address of the sender contract from the source chain.
      address recipient, // The address of the tokens recipient .
      uint256 tokenAmount, // the amount of token to send across network
  );
  // Event emitted when a new route is set (created or updated) between 2 networks
  event EndpointSet(
    uint64 indexed chainSelector, // The chain selector of the destination chain.
    address messageSender, // Message Sending Contract Address
    address messageReceiver, // Message Receiver Contract Address
    bool transferStatus, // route pause status
    uint256 gasLimit, // CCIP gas limit for executing transaction by CCIP protocol on on the destination chain in input
    bool strict // CCIP flag for stop the execution of the queue on the input chain in case of error
  );
  event EndpointDeleted(uint64 indexed chainSelector);

  // Define route between 2 networks 
  struct Endpoint {
    address contractSender; // Message Sending Contract Address
    address contractReceiver; // Message Receiver Contract Address
    bool transferPaused; // if true, the route is paused and transfer cannot proceed
    Client.EVMExtraArgsV1 extraArgs; // define gas settings
  }
  uint64[] public supportedChains; 
  mapping(uint64 => Endpoint) public endpoints;
  IERC20 private iToken;

  /// @notice Constructor initializes the contract with the router address and token contract of this network.
  /// @param _routerAddr The address of the router contract.
  /// @param _tokenAddr The address of the erc20 of this network.
  constructor(address _routerAddr, address _tokenAddr) CCIPReceiver(_routerAddr) {
      iToken = IERC20(_tokenAddr);
  }

  function setEndpoint(
    uint64 _chainSelector,
    address _senderContractAddress,
    address _receiverContractAddress,
    bool _transferStatus,
    uint256 _gasLimit,
    bool _strict
  ) external onlyOwner {
    require(
      _senderContractAddress != address(0) && _receiverContractAddress != address(0) && _gasLimit > 0,
      'Args Cannot be null'
    );
    if (endpoints[_chainSelector].contractSender == address(0))
      supportedChains.push(_chainSelector);

    endpoints[_chainSelector] = Endpoint(
      _senderContractAddress,
      _receiverContractAddress,
      _transferStatus,
      Client.EVMExtraArgsV1(_gasLimit, _strict)
    );

    emit EndpointSet(
      _chainSelector, 
      _senderContractAddress, 
      _receiverContractAddress, 
      _transferStatus, 
      _gasLimit, 
      _strict
    );
  }

  function removeEndpoint(uint64 _chainSelector) external onlyOwner {
    delete endpoints[_chainSelector];
    emit EndpointDeleted(_chainSelector);
  }

  /// @notice Set the router contract address
  /// @param _router New router address
  function setRouter(address _router) external onlyOwner {
    _setRouter(_router);
  }

  /**
   * @notice Set extra args for a chain
   * @param _chainSelector CCIP chain selector
   * @param _gasLimit CCIP gas limit for executing transaction by CCIP protocol on on the destination chain in input
   * @param _strict CCIP flag for stop the execution of the queue on the input chain in case of error
   */
  function setExtraArgs(
    uint64 _chainSelector,
    uint256 _gasLimit,
    bool _strict
  ) external onlyOwner {
    require(endpoints[_chainSelector].contractSender != address(0), 'Chain not supported');
    require(_gasLimit != 0, 'Null gas input');
    endpoints[_chainSelector].extraArgs = Client.EVMExtraArgsV1(_gasLimit, _strict);
  }

  function getMsgFee(
    uint64 _chainSelector,
    address _user,
    uint256 _amount
  ) external view returns (uint256) {
    (, uint256 _fee) = _getMsgFee(_chainSelector, _user, _amount);
    return _fee;
  }

  /// @notice Sends data to receiver on the destination chain.
  /// @notice Pay for fees in native gas.
  /// @dev Assumes your contract has sufficient native gas tokens.
  /// @param _destinationChainSelector The identifier (aka selector) for the destination blockchain.
  /// @param _receiver The address of the recipient on the destination blockchain.
  /// @param _text The text to be sent.
  /// @return messageId The ID of the CCIP message that was sent.
  function bridgeERC20(
      uint64 _destinationChainSelector,
      address _recipient,
      uint256 _amount
  )
      external
      payable
      onlyIfNotPaused(_destinationChainSelector)
      returns (bytes32 messageId)
  {
      Endpoint memory destination = endpoints[_destinationChainSelector];
      if (destination.messageReceiver != address(0))
          revert DestinationChainNotAllowlisted(_destinationChainSelector);

      if(destination.transferPaused == true) 
          revert RoutePaused(_destinationChainSelector); 

      // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
      // address(0) means fees are paid in native gas
      (Client.EVM2AnyMessage memory message, uint256 fees) = _buildMessage(
          destination,
          _recipient,
          _amount
      );

      // Ensure fees are paid with sent tx
      if (fees > msg.value)
          revert NotEnoughBalanceForFees(msg.value, fees);
      // Refund if sent amount exceed fees
      uint256 refund = msg.value - fees;
      if (refund > 0) {
        (bool status, ) = payable(_msgSender()).call{ value: refund }('');
        require(status, 'REFUND');
      }

      // Transfer token from sender to bridge
      status = iToken.transferFrom(msg.sender, address(this), _amount);
      if(!status) revert("Cannot transfer tokens to bridge");
      // Burn token on this chain to mint on destination chain
      status = iToken.burn(_amount);
      if(!status) revert("Cannot burn tokens");

      // Send the CCIP message through the iRouter and store the returned CCIP message ID
      messageId = iRouter.ccipSend{value: fees}(
          _destinationChainSelector,
          message
      );

      // Emit an event with message details
      emit TransferInit(
          messageId,
          _destinationChainSelector,
          destination.contractReceiver,
          _recipient,
          _amount,
          fees
      );

      // Return the CCIP message ID
      return messageId;
  }

  /// handle a received CCIP message
  function _ccipReceive(
      Client.Any2EVMMessage memory _message
  ) internal override {
  if (abi.decode(_message.sender, (address)) != endpoints[_message.sourceChainSelector].contractSender)
    revert SourceChainNotAllowlisted(_message.sourceChainSelector)
  // decode cross chain _message
  (uint256 amount, address recipient) = abi.decode( _message.data, (uint256, address));
  // mint token to recipient
  iToken.mint(recipient, amount);
  
  emit TransferCompleted(
      _message.messageId,
      _message.sourceChainSelector, // fetch the source chain identifier (aka selector)
      abi.decode(_message.sender, (address)), // abi-decoding of the sender address,
      recipient,
      amount
  );
  }

  /// @notice Construct a CCIP token and data message.
  /// @dev This function will create an EVM2AnyMessage struct with all the necessary information for crosschain transfer.
  /// @param _receiver The address of the receiver contract.
  /// @param _text The string data to be sent.
  /// @param _token The token to be transferred.
  /// @param _amount The amount of the token to be transferred.
  /// @param _feeTokenAddress The address of the token used for fees. Set address(0) for native gas.
  /// @return Client.EVM2AnyMessage Returns an EVM2AnyMessage struct which contains information for sending a CCIP message.
  function _buildMessage(
      Endpoint memory _destination,
      address _recipient,
      uint256 _amount
  ) private pure returns (Client.EVM2AnyMessage memory) {
      // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
      Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
          receiver: abi.encode(_destination.contractReceiver), // ABI-encoded receiver address
          data: abi.encode(_amount, _recipient),
          tokenAmounts: new Client.EVMTokenAmount[](0), // Empty array as no tokens are transferred
          extraArgs: Client._argsToBytes(
              // Additional arguments, setting gas limit
              _destination.extraArgs
          ),
          feeToken: address(0) // set fees to native token
      });
      return evm2AnyMessage;
  }

  function _getMsgFee(
    uint64 _chainSelector,
    address _user,
    uint256 _amount
  ) internal view returns (Client.EVM2AnyMessage memory, uint256) {
    Endpoint memory destination = endpoints[_chainSelector];
    Client.EVM2AnyMessage memory _evm2AnyMessage = _buildMsg(
      destination,
      _user,
      _amount
    );
    return (
      _evm2AnyMessage,
      iRouter.getFee(_chainSelector, _evm2AnyMessage)
    );
  }


  /// @notice Allows the contract owner to withdraw the entire balance of Ether or native token from the contract.
  /// @dev This function reverts if there are no funds to withdraw or if the transfer fails.
  /// It should only be callable by the owner of the contract.
  /// @param _beneficiary The address to which the Ether should be sent.
  function withdraw(address _beneficiary) public onlyOwner {
      // Retrieve the balance of this contract
      uint256 amount = address(this).balance;
      // Revert if there is nothing to withdraw
      if (amount == 0) revert NothingToWithdraw();
      // Attempt to send the funds, capturing the success status and discarding any return data
      (bool status, ) = _beneficiary.call{value: amount}("");
      // Revert if the send failed, with information about the attempted transfer
      if (!status) revert FailedToWithdrawNative(msg.sender, _beneficiary, amount);
  }

  /// @notice Allows the owner of the contract to withdraw all tokens of a specific ERC20 token.
  /// @dev This function reverts with a 'NothingToWithdraw' error if there are no tokens to withdraw.
  /// @param _beneficiary The address to which the tokens will be sent.
  /// @param _token The contract address of the ERC20 token to be withdrawn.
  function withdrawToken(
      address _beneficiary,
      address _token
  ) public onlyOwner {
      // Retrieve the balance of this contract
      uint256 amount = IERC20(_token).balanceOf(address(this));
      // Revert if there is nothing to withdraw
      if (amount == 0) revert NothingToWithdraw();
      IERC20(_token).safeTransfer(_beneficiary, amount);
  }

  /// @notice Fallback function to allow the contract to receive Ether.
  /// @dev This function has no function body, making it a default function for receiving Ether.
  /// It is automatically called when Ether is sent to the contract without any data.
  receive() external payable {}
}
