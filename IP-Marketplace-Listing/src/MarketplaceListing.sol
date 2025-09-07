// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/*//////////////////////////////////////////////////////////////
                          Errors (messages)
//////////////////////////////////////////////////////////////*/
library Errors {
    string constant INVALID_IP_ASSET = "invalid ip asset";
    string constant NOT_OWNER        = "Caller not asset owner";
    string constant NOT_APPROVED     = "ip asset not approved by owner";
}

/*//////////////////////////////////////////////////////////////
                        External Interfaces
//////////////////////////////////////////////////////////////*/

/// Minimal ERC721 used by le listing (ownerOf + isApprovedForAll)
interface IERC721Minimal {
    function ownerOf(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
}

/// Marketplace cible (fonction créée telle que dans le Cairo)
interface IMarketplace {
    function create_listing(
        address assetContract,
        uint256 tokenId,
        uint256 startTime,
        uint256 secondsUntilEndTime,
        uint256 quantityToList,
        address currencyToAccept,
        uint256 buyoutPricePerToken,
        uint256 tokenTypeOfListing
    ) external;
}

/// Interface du contrat MIPListing (optionnelle mais fidèle au Cairo)
interface IMIPListing {
    function create_listing(
        address assetContractAddress,
        uint256 tokenId,
        uint256 startTime,
        uint256 secondsUntilEndTime,
        uint256 quantityToList,
        address currencyToAccept,
        uint256 buyoutPricePerToken,
        uint256 tokenTypeOfListing
    ) external;

    function update_ip_marketplace_address(address new_address) external;
}

/*//////////////////////////////////////////////////////////////
                           MIPListing
//////////////////////////////////////////////////////////////*/

contract MIPListing is Ownable, IMIPListing {
    /// Adresse du contrat marketplace de destination
    address public ip_marketplace_address;

    /*=============================*
     *            Events           *
     *=============================*/

    event ListingCreated(
        uint256 indexed token_id,
        address lister,
        uint64  date
    );

    event IPMarketplaceUpdated(
        address indexed ipMarketplace,
        uint64  date
    );

    /*=============================*
     *          Constructor        *
     *=============================*/

    constructor(address owner_, address ip_marketplace_) Ownable(owner_) {
        ip_marketplace_address = ip_marketplace_;
    }

    /*=============================*
     *        Core Functions       *
     *=============================*/

    /// Reprise fidèle de la signature Cairo (noms et ordre des params)
    function create_listing(
        address assetContractAddress,
        uint256 tokenId,
        uint256 startTime,
        uint256 secondsUntilEndTime,
        uint256 quantityToList,
        address currencyToAccept,
        uint256 buyoutPricePerToken,
        uint256 tokenTypeOfListing
    ) external override {
        address caller = msg.sender;

        // asset non nul
        require(assetContractAddress != address(0), Errors.INVALID_IP_ASSET);

        // vérifier que l’asset existe (ownerOf ne revert pas silencieusement en Solidity,
        // donc on encapsule dans un try/catch pour retourner address(0) si invalide)
        address owner_ = _ownerOfOrZero(assetContractAddress, tokenId);
        require(owner_ != address(0), Errors.INVALID_IP_ASSET);

        // vérifier ownership par le caller
        require(owner_ == caller, Errors.NOT_OWNER);

        // vérifier approval « pour tout » (comme dans le Cairo)
        require(
            IERC721Minimal(assetContractAddress).isApprovedForAll(caller, address(this)),
            Errors.NOT_APPROVED
        );

        // appeler le marketplace cible
        IMarketplace(ip_marketplace_address).create_listing(
            assetContractAddress,
            tokenId,
            startTime,
            secondsUntilEndTime,
            quantityToList,
            currencyToAccept,
            buyoutPricePerToken,
            tokenTypeOfListing
        );

        emit ListingCreated(tokenId, caller, uint64(block.timestamp));
    }

    function update_ip_marketplace_address(address new_address) external override onlyOwner {
        ip_marketplace_address = new_address;
        emit IPMarketplaceUpdated(new_address, uint64(block.timestamp));
    }

    /*=============================*
     *         Internal utils      *
     *=============================*/

    /// ownerOf « safe » : renvoie address(0) si l’appel revert (token inexistant)
    function _ownerOfOrZero(address nft, uint256 tokenId) internal view returns (address) {
        try IERC721(nft).ownerOf(tokenId) returns (address owner_) {
            return owner_;
        } catch {
            return address(0);
        }
    }
}
