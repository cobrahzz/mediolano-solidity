// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * Interface calquée sur le trait Cairo.
 * felt252 -> bytes32, ByteArray -> string
 */
interface IIPIdentity {
    struct IPIDData {
        string   metadata_uri;
        string   ip_type;
        string   license_terms;
        bool     is_verified;
        uint64   created_at;
        uint64   updated_at;
        uint256  collection_id;
        uint256  royalty_rate;        // en bps (p.ex. 250 = 2.5%)
        uint256  licensing_fee;
        bool     commercial_use;
        bool     derivative_works;
        bool     attribution_required;
        string   metadata_standard;   // "ERC721", "IPFS", etc.
        string   external_url;
        string   tags;                // CSV
        string   jurisdiction;        // juridiction légale
    }

    // Core
    function register_ip_id(
        bytes32 ip_id,
        string calldata metadata_uri,
        string calldata ip_type,
        string calldata license_terms,
        uint256 collection_id,
        uint256 royalty_rate,
        uint256 licensing_fee,
        bool commercial_use,
        bool derivative_works,
        bool attribution_required,
        string calldata metadata_standard,
        string calldata external_url,
        string calldata tags,
        string calldata jurisdiction
    ) external returns (uint256 tokenId);

    function update_ip_id_metadata(bytes32 ip_id, string calldata new_metadata_uri) external;

    function update_ip_id_licensing(
        bytes32 ip_id,
        string calldata license_terms,
        uint256 royalty_rate,
        uint256 licensing_fee,
        bool commercial_use,
        bool derivative_works,
        bool attribution_required
    ) external;

    function transfer_ip_ownership(bytes32 ip_id, address new_owner) external;

    function verify_ip_id(bytes32 ip_id) external;

    // Getters
    function get_ip_id_data(bytes32 ip_id) external view returns (IPIDData memory);
    function get_ip_owner(bytes32 ip_id) external view returns (address);
    function get_ip_token_id(bytes32 ip_id) external view returns (uint256);
    function is_ip_verified(bytes32 ip_id) external view returns (bool);

    function get_ip_licensing_terms(bytes32 ip_id)
        external view
        returns (
            string memory license_terms,
            uint256 royalty_rate,
            uint256 licensing_fee,
            bool commercial_use,
            bool derivative_works,
            bool attribution_required
        );

    function get_ip_metadata_info(bytes32 ip_id)
        external view
        returns (
            string memory metadata_uri,
            string memory ip_type,
            string memory metadata_standard,
            string memory external_url
        );

    // Batch / filtres
    function get_multiple_ip_data(bytes32[] calldata ip_ids) external view returns (IPIDData[] memory);
    function get_owner_ip_ids(address owner) external view returns (bytes32[] memory);
    function get_verified_ip_ids(uint256 limit, uint256 offset) external view returns (bytes32[] memory);
    function get_ip_ids_by_collection(uint256 collection_id) external view returns (bytes32[] memory);
    function get_ip_ids_by_type(string calldata ip_type) external view returns (bytes32[] memory);

    // Utilitaires
    function is_ip_id_registered(bytes32 ip_id) external view returns (bool);
    function get_total_registered_ips() external view returns (uint256);
    function can_use_commercially(bytes32 ip_id) external view returns (bool);
    function can_create_derivatives(bytes32 ip_id) external view returns (bool);
    function requires_attribution(bytes32 ip_id) external view returns (bool);
}

/**
 * Événements supplémentaires (mêmes noms/champs que Cairo).
 */
interface EventsDefs {
    event IPIDRegistered(
        bytes32 indexed ip_id,
        address indexed owner,
        uint256 token_id,
        string ip_type,
        uint256 collection_id,
        string metadata_uri,
        string metadata_standard,
        bool commercial_use,
        bool derivative_works,
        bool attribution_required,
        uint64 timestamp
    );

    event IPIDMetadataUpdated(
        bytes32 indexed ip_id,
        address indexed owner,
        string old_metadata_uri,
        string new_metadata_uri,
        uint64 timestamp
    );

    event IPIDLicensingUpdated(
        bytes32 indexed ip_id,
        address indexed owner,
        string license_terms,
        uint256 royalty_rate,
        uint256 licensing_fee,
        bool commercial_use,
        bool derivative_works,
        bool attribution_required,
        uint64 timestamp
    );

    event IPIDOwnershipTransferred(
        bytes32 indexed ip_id,
        address indexed previous_owner,
        address indexed new_owner,
        uint256 token_id,
        uint64 timestamp
    );

    event IPIDVerified(
        bytes32 indexed ip_id,
        address indexed owner,
        address verifier,
        uint64 timestamp
    );

    event IPIDCollectionLinked(
        bytes32 indexed ip_id,
        uint256 indexed collection_id,
        address owner,
        uint64 timestamp
    );
}

contract IPIdentity is IIPIdentity, ERC721URIStorage, Ownable, EventsDefs {
    // ----- Errors (messages proches de Cairo) -----
    string private constant ERROR_ALREADY_REGISTERED = "IP ID already registered";
    string private constant ERROR_NOT_OWNER          = "Caller is not the owner";
    string private constant ERROR_INVALID_IP_ID      = "Invalid IP ID";

    // ----- Storage -----
    // felt252 -> tokenId
    mapping(bytes32 => uint256) private _ipIdToTokenId;
    // felt252 -> data
    mapping(bytes32 => IPIDData) private _ipData;

    // Compteur de tokenIds (0 est réservé comme sentinelle "non-enregistre")
    uint256 private _tokenCounter;

    // Indexations
    // owner -> idx -> ipId
    mapping(address => mapping(uint256 => bytes32)) private _ownerToIpIds;
    mapping(address => uint256) private _ownerIpCount;

    // collectionId -> idx -> ipId
    mapping(uint256 => mapping(uint256 => bytes32)) private _collectionToIpIds;
    mapping(uint256 => uint256) private _collectionIpCount;

    // typeHash -> idx -> ipId
    mapping(bytes32 => mapping(uint256 => bytes32)) private _typeToIpIds;
    mapping(bytes32 => uint256) private _typeIpCount;

    // liste des verifications
    mapping(uint256 => bytes32) private _verifiedIpIds;
    uint256 private _verifiedCount;

    // total registrés
    uint256 private _totalRegistered;

    // baseURI
    string private _baseUri;

    // ----- Constructor -----
    constructor(
        address initialOwner,
        string memory name_,
        string memory symbol_,
        string memory base_uri_
    ) ERC721(name_, symbol_) Ownable(initialOwner) {
        _baseUri = base_uri_;
    }

    // ----- Internals -----
    function _now64() private view returns (uint64) {
        return uint64(block.timestamp);
    }

    function _typeHash(string memory ip_type) private pure returns (bytes32) {
        return keccak256(bytes(ip_type));
    }

    // ----- ERC721 overrides -----
    function _baseURI() internal view override returns (string memory) {
        return _baseUri;
    }

    function tokenURI(uint256 tokenId)
        public view override(ERC721URIStorage, ERC721)
        returns (string memory)
    {
        return ERC721URIStorage.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public view override(ERC721URIStorage, ERC721)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // =========================================================
    // ===============   Core (parité Cairo)   =================
    // =========================================================
    function register_ip_id(
        bytes32 ip_id,
        string calldata metadata_uri,
        string calldata ip_type,
        string calldata license_terms,
        uint256 collection_id,
        uint256 royalty_rate,
        uint256 licensing_fee,
        bool commercial_use,
        bool derivative_works,
        bool attribution_required,
        string calldata metadata_standard,
        string calldata external_url,
        string calldata tags,
        string calldata jurisdiction
    ) external override returns (uint256 tokenId) {
        require(_ipIdToTokenId[ip_id] == 0, ERROR_ALREADY_REGISTERED);

        // mint NFT
        tokenId = ++_tokenCounter;
        _safeMint(msg.sender, tokenId);
        _setTokenURI(tokenId, metadata_uri);

        // stocker data
        IPIDData memory d = IPIDData({
            metadata_uri: metadata_uri,
            ip_type: ip_type,
            license_terms: license_terms,
            is_verified: false,
            created_at: _now64(),
            updated_at: _now64(),
            collection_id: collection_id,
            royalty_rate: royalty_rate,
            licensing_fee: licensing_fee,
            commercial_use: commercial_use,
            derivative_works: derivative_works,
            attribution_required: attribution_required,
            metadata_standard: metadata_standard,
            external_url: external_url,
            tags: tags,
            jurisdiction: jurisdiction
        });

        _ipData[ip_id] = d;
        _ipIdToTokenId[ip_id] = tokenId;

        // index owner
        uint256 oc = _ownerIpCount[msg.sender];
        _ownerToIpIds[msg.sender][oc] = ip_id;
        _ownerIpCount[msg.sender] = oc + 1;

        // index collection
        if (collection_id != 0) {
            uint256 cc = _collectionIpCount[collection_id];
            _collectionToIpIds[collection_id][cc] = ip_id;
            _collectionIpCount[collection_id] = cc + 1;
        }

        // index type
        bytes32 th = _typeHash(ip_type);
        uint256 tc = _typeIpCount[th];
        _typeToIpIds[th][tc] = ip_id;
        _typeIpCount[th] = tc + 1;

        // total
        _totalRegistered += 1;

        // events
        emit IPIDRegistered(
            ip_id,
            msg.sender,
            tokenId,
            ip_type,
            collection_id,
            metadata_uri,
            metadata_standard,
            commercial_use,
            derivative_works,
            attribution_required,
            _now64()
        );

        if (collection_id != 0) {
            emit IPIDCollectionLinked(ip_id, collection_id, msg.sender, _now64());
        }
    }

    function update_ip_id_metadata(bytes32 ip_id, string calldata new_metadata_uri) external override {
        uint256 tokenId = _ipIdToTokenId[ip_id];
        require(tokenId != 0, ERROR_INVALID_IP_ID);
        address owner_ = ownerOf(tokenId);
        require(msg.sender == owner_, ERROR_NOT_OWNER);

        string memory old = _ipData[ip_id].metadata_uri;
        _ipData[ip_id].metadata_uri = new_metadata_uri;
        _ipData[ip_id].updated_at = _now64();

        // garder l’ERC721 en phase avec les métadonnées
        _setTokenURI(tokenId, new_metadata_uri);

        emit IPIDMetadataUpdated(ip_id, owner_, old, new_metadata_uri, _now64());
    }

    function update_ip_id_licensing(
        bytes32 ip_id,
        string calldata license_terms,
        uint256 royalty_rate,
        uint256 licensing_fee,
        bool commercial_use,
        bool derivative_works,
        bool attribution_required
    ) external override {
        uint256 tokenId = _ipIdToTokenId[ip_id];
        require(tokenId != 0, ERROR_INVALID_IP_ID);
        address owner_ = ownerOf(tokenId);
        require(msg.sender == owner_, ERROR_NOT_OWNER);

        IPIDData storage d = _ipData[ip_id];
        d.license_terms = license_terms;
        d.royalty_rate = royalty_rate;
        d.licensing_fee = licensing_fee;
        d.commercial_use = commercial_use;
        d.derivative_works = derivative_works;
        d.attribution_required = attribution_required;
        d.updated_at = _now64();

        emit IPIDLicensingUpdated(
            ip_id,
            owner_,
            license_terms,
            royalty_rate,
            licensing_fee,
            commercial_use,
            derivative_works,
            attribution_required,
            _now64()
        );
    }

    function transfer_ip_ownership(bytes32 ip_id, address new_owner) external override {
        uint256 tokenId = _ipIdToTokenId[ip_id];
        require(tokenId != 0, ERROR_INVALID_IP_ID);

        address current = ownerOf(tokenId);
        require(msg.sender == current, ERROR_NOT_OWNER);

        // transfert ERC721
        _safeTransfer(current, new_owner, tokenId, "");

        // mise à jour des index owner (swap & pop like)
        uint256 oc = _ownerIpCount[current];
        uint256 found = oc; // invalid
        for (uint256 i = 0; i < oc; i++) {
            if (_ownerToIpIds[current][i] == ip_id) { found = i; break; }
        }
        if (found < oc) {
            uint256 last = oc - 1;
            if (found != last) {
                bytes32 lastIp = _ownerToIpIds[current][last];
                _ownerToIpIds[current][found] = lastIp;
            }
            delete _ownerToIpIds[current][last];
            _ownerIpCount[current] = last;
        }

        uint256 nc = _ownerIpCount[new_owner];
        _ownerToIpIds[new_owner][nc] = ip_id;
        _ownerIpCount[new_owner] = nc + 1;

        emit IPIDOwnershipTransferred(ip_id, current, new_owner, tokenId, _now64());
    }

    function verify_ip_id(bytes32 ip_id) external override onlyOwner {
        uint256 tokenId = _ipIdToTokenId[ip_id];
        require(tokenId != 0, ERROR_INVALID_IP_ID);

        if (!_ipData[ip_id].is_verified) {
            _ipData[ip_id].is_verified = true;
            _ipData[ip_id].updated_at = _now64();

            _verifiedIpIds[_verifiedCount] = ip_id;
            _verifiedCount += 1;

            emit IPIDVerified(ip_id, ownerOf(tokenId), msg.sender, _now64());
        }
    }

    // =========================================================
    // =======================  Getters  =======================
    // =========================================================
    function get_ip_id_data(bytes32 ip_id) external view override returns (IPIDData memory) {
        require(_ipIdToTokenId[ip_id] != 0, ERROR_INVALID_IP_ID);
        return _ipData[ip_id];
    }

    function get_ip_owner(bytes32 ip_id) external view override returns (address) {
        uint256 tokenId = _ipIdToTokenId[ip_id];
        require(tokenId != 0, ERROR_INVALID_IP_ID);
        return ownerOf(tokenId);
    }

    function get_ip_token_id(bytes32 ip_id) external view override returns (uint256) {
        uint256 tokenId = _ipIdToTokenId[ip_id];
        require(tokenId != 0, ERROR_INVALID_IP_ID);
        return tokenId;
    }

    function is_ip_verified(bytes32 ip_id) external view override returns (bool) {
        uint256 tokenId = _ipIdToTokenId[ip_id];
        if (tokenId == 0) return false;
        return _ipData[ip_id].is_verified;
    }

    function get_ip_licensing_terms(bytes32 ip_id)
        external view override
        returns (
            string memory license_terms,
            uint256 royalty_rate,
            uint256 licensing_fee,
            bool commercial_use,
            bool derivative_works,
            bool attribution_required
        )
    {
        require(_ipIdToTokenId[ip_id] != 0, ERROR_INVALID_IP_ID);
        IPIDData storage d = _ipData[ip_id];
        return (d.license_terms, d.royalty_rate, d.licensing_fee, d.commercial_use, d.derivative_works, d.attribution_required);
    }

    function get_ip_metadata_info(bytes32 ip_id)
        external view override
        returns (
            string memory metadata_uri,
            string memory ip_type,
            string memory metadata_standard,
            string memory external_url
        )
    {
        require(_ipIdToTokenId[ip_id] != 0, ERROR_INVALID_IP_ID);
        IPIDData storage d = _ipData[ip_id];
        return (d.metadata_uri, d.ip_type, d.metadata_standard, d.external_url);
    }

    function get_multiple_ip_data(bytes32[] calldata ip_ids) external view override returns (IPIDData[] memory out) {
        // 1ère passe: compter
        uint256 n;
        for (uint256 i = 0; i < ip_ids.length; i++) {
            if (_ipIdToTokenId[ip_ids[i]] != 0) n++;
        }
        out = new IPIDData[](n);
        // 2e passe: remplir
        uint256 k;
        for (uint256 i = 0; i < ip_ids.length; i++) {
            bytes32 id = ip_ids[i];
            if (_ipIdToTokenId[id] != 0) {
                out[k++] = _ipData[id];
            }
        }
    }

    function get_owner_ip_ids(address owner_) external view override returns (bytes32[] memory out) {
        uint256 c = _ownerIpCount[owner_];
        // compter non-zéro (au cas où)
        uint256 n;
        for (uint256 i = 0; i < c; i++) {
            if (_ownerToIpIds[owner_][i] != bytes32(0)) n++;
        }
        out = new bytes32[](n);
        uint256 k;
        for (uint256 i = 0; i < c; i++) {
            bytes32 id = _ownerToIpIds[owner_][i];
            if (id != bytes32(0)) out[k++] = id;
        }
    }

    function get_verified_ip_ids(uint256 limit, uint256 offset) external view override returns (bytes32[] memory out) {
        uint256 end = _verifiedCount;
        if (offset > end) return new bytes32;
        uint256 maxEnd = offset + limit;
        if (maxEnd < end) end = maxEnd;
        uint256 n = end - offset;
        out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _verifiedIpIds[offset + i];
        }
    }

    function get_ip_ids_by_collection(uint256 collection_id) external view override returns (bytes32[] memory out) {
        uint256 c = _collectionIpCount[collection_id];
        // compter non-zéro
        uint256 n;
        for (uint256 i = 0; i < c; i++) {
            if (_collectionToIpIds[collection_id][i] != bytes32(0)) n++;
        }
        out = new bytes32[](n);
        uint256 k;
        for (uint256 i = 0; i < c; i++) {
            bytes32 id = _collectionToIpIds[collection_id][i];
            if (id != bytes32(0)) out[k++] = id;
        }
    }

    function get_ip_ids_by_type(string calldata ip_type) external view override returns (bytes32[] memory out) {
        bytes32 th = _typeHash(ip_type);
        uint256 c = _typeIpCount[th];
        // compter non-zéro
        uint256 n;
        for (uint256 i = 0; i < c; i++) {
            if (_typeToIpIds[th][i] != bytes32(0)) n++;
        }
        out = new bytes32[](n);
        uint256 k;
        for (uint256 i = 0; i < c; i++) {
            bytes32 id = _typeToIpIds[th][i];
            if (id != bytes32(0)) out[k++] = id;
        }
    }

    // Utilitaires
    function is_ip_id_registered(bytes32 ip_id) external view override returns (bool) {
        return _ipIdToTokenId[ip_id] != 0;
    }

    function get_total_registered_ips() external view override returns (uint256) {
        return _totalRegistered;
    }

    function can_use_commercially(bytes32 ip_id) external view override returns (bool) {
        if (_ipIdToTokenId[ip_id] == 0) return false;
        return _ipData[ip_id].commercial_use;
    }

    function can_create_derivatives(bytes32 ip_id) external view override returns (bool) {
        if (_ipIdToTokenId[ip_id] == 0) return false;
        return _ipData[ip_id].derivative_works;
    }

    function requires_attribution(bytes32 ip_id) external view override returns (bool) {
        if (_ipIdToTokenId[ip_id] == 0) return false;
        return _ipData[ip_id].attribution_required;
    }
}
