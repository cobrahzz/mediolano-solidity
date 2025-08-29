// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title VisibilityManagement
/// @notice Gestion d’un statut de visibilité (0/1) indexé par (tokenAddress, assetId, owner).
///         setVisibility() prend l’adresse appelante comme "owner", comme dans la version Cairo.
contract VisibilityManagement {
    // visibility[tokenAddress][assetId][owner] => status (0 ou 1)
    mapping(address => mapping(uint256 => mapping(address => uint8))) public visibility;

    event VisibilityChanged(
        address indexed tokenAddress,
        uint256 indexed assetId,
        address indexed owner,
        uint8 visibilityStatus
    );

    /// @notice Définit le statut pour (tokenAddress, assetId, msg.sender).
    function setVisibility(
        address tokenAddress,
        uint256 assetId,
        uint8 visibilityStatus
    ) external {
        require(
            visibilityStatus == 0 || visibilityStatus == 1,
            "Invalid visibility status"
        );

        visibility[tokenAddress][assetId][msg.sender] = visibilityStatus;
        emit VisibilityChanged(tokenAddress, assetId, msg.sender, visibilityStatus);
    }

    /// @notice Lit le statut stocké pour (tokenAddress, assetId, owner).
    function getVisibility(
        address tokenAddress,
        uint256 assetId,
        address owner
    ) external view returns (uint8) {
        return visibility[tokenAddress][assetId][owner];
    }
}
