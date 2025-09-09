// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Governance.sol";

abstract contract BerneCompliance is Governance {
    // Compliance records and authority structs
    struct ComplianceRecord {
        uint256 assetId;
        bytes32 complianceStatus;
        bytes32 countryOfOrigin;
        uint64  publicationDate;
        address registrationAuthority;
        uint64  verificationTimestamp;
        string  complianceEvidenceUri;
        uint32  automaticProtectionCount;
        uint32  manualRegistrationCount;
        uint64  protectionDuration;
        bool    isAnonymousWork;
        bool    isCollectiveWork;
        bool    renewalRequired;
        uint64  nextRenewalDate;
    }

    struct ComplianceVerificationRequest {
        uint256 requestId;
        uint256 assetId;
        address requester;
        bytes32 requestedStatus;
        string  evidenceUri;
        bytes32 countryOfOrigin;
        uint64  publicationDate;
        bytes32 workType;
        bool    isOriginalWork;
        uint32  authorsCount;
        uint64  requestTimestamp;
        bool    isProcessed;
        bool    isApproved;
        string  verifierNotes;
    }

    struct CountryComplianceRequirements {
        bytes32 countryCode;
        bool    isBerneSignatory;
        bool    automaticProtection;
        bool    registrationRequired;
        uint16  protectionDurationYears;
        bool    noticeRequired;
        bool    depositRequired;
        uint16  translationRightsDuration;
        bool    moralRightsProtected;
    }

    struct ComplianceAuthority {
        address authorityAddress;
        string  authorityName;
        uint32  authorizedCountriesCount;
        bytes32 authorityType;
        bool    isActive;
        uint256 verificationCount;
        uint64  registrationTimestamp;
        string  credentialsUri;
    }

    // Compliance events
    event ComplianceVerificationRequested(
        uint256 indexed requestId,
        uint256 indexed assetId,
        address requester,
        bytes32 requestedStatus,
        bytes32 countryOfOrigin,
        uint64 timestamp
    );
    event ComplianceVerified(
        uint256 indexed assetId,
        bytes32 newStatus,
        address verifiedBy,
        bytes32 countryOfOrigin,
        uint64 protectionDuration,
        uint64 timestamp
    );
    event ComplianceAuthorityRegistered(address indexed authorityAddress, string authorityName, bytes32 authorityType, uint32 authorizedCountriesCount, uint64 timestamp);
    event ProtectionRenewalRequired(uint256 indexed assetId, bytes32 currentStatus, uint64 renewalDeadline, uint64 timestamp);
    event ProtectionExpired(uint256 indexed assetId, bytes32 previousStatus, uint64 expirationTimestamp, uint64 timestamp);
    event CrossBorderProtectionUpdated(uint256 indexed assetId, bytes32 countryCode, bool protectionStatus, address updatedBy, uint64 timestamp);

    mapping(uint256 => ComplianceRecord) internal complianceRecords;
    mapping(address => ComplianceAuthority) internal complianceAuthorities;
    mapping(uint256 => ComplianceVerificationRequest) internal complianceRequests;

    mapping(bytes32 => CountryComplianceRequirements) public countryRequirements;
    uint256 public nextVerificationRequestId = 1;
    mapping(address => mapping(bytes32 => bool)) public authorityCountryAllowed;
    mapping(address => bytes32[]) public authorityCountries;
    mapping(uint256 => mapping(bytes32 => bool)) public internationalProtection;
    mapping(uint256 => bytes32[]) public automaticProtectionCountries;
    mapping(uint256 => bytes32[]) public manualRegistrationCountries;
    mapping(bytes32 => uint256[]) public assetsByStatus;

    // Register a compliance authority (government or certified organization)
    function registerComplianceAuthority(
        address authority,
        string calldata name_,
        bytes32[] calldata authorizedCountries,
        bytes32 authorityType,
        string calldata credentialsUri
    ) external onlyOwner returns (bool) {
        require(authority != address(0), "Bad authority");
        require(
            authorityType == "GOVERNMENT" || authorityType == "CERTIFIED_ORG" || authorityType == "LEGAL_EXPERT",
            "Invalid authority type"
        );

        ComplianceAuthority memory a = ComplianceAuthority({
            authorityAddress: authority,
            authorityName: name_,
            authorizedCountriesCount: uint32(authorizedCountries.length),
            authorityType: authorityType,
            isActive: true,
            verificationCount: 0,
            registrationTimestamp: _now(),
            credentialsUri: credentialsUri
        });
        complianceAuthorities[authority] = a;

        // Set up authorized countries for this authority
        delete authorityCountries[authority];
        for (uint256 i = 0; i < authorizedCountries.length; i++) {
            bytes32 c = authorizedCountries[i];
            authorityCountryAllowed[authority][c] = true;
            authorityCountries[authority].push(c);
        }

        emit ComplianceAuthorityRegistered(authority, name_, authorityType, uint32(authorizedCountries.length), _now());
        return true;
    }

    function deactivateComplianceAuthority(address authority) external onlyOwner returns (bool) {
        ComplianceAuthority storage a = complianceAuthorities[authority];
        require(a.authorityAddress != address(0), "Authority not found");
        a.isActive = false;
        return true;
    }

    function getComplianceAuthority(address authority) external view returns (
        address authorityAddress,
        uint32  authorizedCountriesCount,
        bytes32 authorityType,
        bool    isActive,
        uint256 verificationCount,
        uint64  registrationTimestamp
    ) {
        ComplianceAuthority storage a = complianceAuthorities[authority];
        return (
            a.authorityAddress,
            a.authorizedCountriesCount,
            a.authorityType,
            a.isActive,
            a.verificationCount,
            a.registrationTimestamp
        );
    }

    function getComplianceAuthorityName(address authority) external view returns (string memory) {
        return complianceAuthorities[authority].authorityName;
    }

    function getComplianceAuthorityCredentialsUri(address authority) external view returns (string memory) {
        return complianceAuthorities[authority].credentialsUri;
    }

    function isAuthorizedForCountry(address authority, bytes32 country) public view returns (bool) {
        ComplianceAuthority memory a = complianceAuthorities[authority];
        if (!a.isActive) return false;
        return authorityCountryAllowed[authority][country];
    }

    function setCountryRequirements(bytes32 country, CountryComplianceRequirements calldata req) external onlyOwner returns (bool) {
        require(country != bytes32(0), "Bad country code");
        countryRequirements[country] = req;
        return true;
    }

    function getCountryRequirements(bytes32 country) public view returns (CountryComplianceRequirements memory) {
        CountryComplianceRequirements memory r = countryRequirements[country];
        if (r.countryCode == 0) {
            // Default requirements for Berne signatories if not overridden
            return CountryComplianceRequirements({
                countryCode: country,
                isBerneSignatory: true,
                automaticProtection: true,
                registrationRequired: false,
                protectionDurationYears: 70,
                noticeRequired: false,
                depositRequired: false,
                translationRightsDuration: 10,
                moralRightsProtected: true
            });
        }
        return r;
    }

    function getBerneSignatoryCountries() external pure returns (bytes32[] memory) {
        bytes32[] memory arr = new bytes32[](21);
        arr[0]  = bytes32("US");
        arr[1]  = bytes32("UK");
        arr[2]  = bytes32("FR");
        arr[3]  = bytes32("DE");
        arr[4]  = bytes32("JP");
        arr[5]  = bytes32("CA");
        arr[6]  = bytes32("AU");
        arr[7]  = bytes32("IT");
        arr[8]  = bytes32("ES");
        arr[9]  = bytes32("NL");
        arr[10] = bytes32("SE");
        arr[11] = bytes32("CH");
        arr[12] = bytes32("NO");
        arr[13] = bytes32("DK");
        arr[14] = bytes32("FI");
        arr[15] = bytes32("AT");
        arr[16] = bytes32("BE");
        arr[17] = bytes32("PT");
        arr[18] = bytes32("GR");
        arr[19] = bytes32("IE");
        arr[20] = bytes32("PL");
        return arr;
    }

    // Asset owner requests compliance verification for their asset (e.g., to mark as Berne-compliant)
    function requestComplianceVerification(
        uint256 assetId,
        bytes32 requestedStatus,
        string calldata evidenceUri,
        bytes32 countryOfOrigin,
        uint64  publicationDate,
        bytes32 workType,
        bool    isOriginalWork,
        address[] calldata authors
    ) external whenNotPaused onlyAssetOwner(assetId) returns (uint256) {
        require(verifyAssetOwnership(assetId), "Asset not found");
        require(countryOfOrigin != 0, "Country required");
        require(publicationDate > 0, "Publication date required");

        uint256 requestId = nextVerificationRequestId++;
        complianceRequests[requestId] = ComplianceVerificationRequest({
            requestId: requestId,
            assetId: assetId,
            requester: _msgSender(),
            requestedStatus: requestedStatus,
            evidenceUri: evidenceUri,
            countryOfOrigin: countryOfOrigin,
            publicationDate: publicationDate,
            workType: workType,
            isOriginalWork: isOriginalWork,
            authorsCount: uint32(authors.length),
            requestTimestamp: _now(),
            isProcessed: false,
            isApproved: false,
            verifierNotes: ""
        });

        emit ComplianceVerificationRequested(requestId, assetId, _msgSender(), requestedStatus, countryOfOrigin, _now());
        return requestId;
    }

    // Compliance authority processes a verification request
    function processComplianceVerification(
        uint256 requestId,
        bool approved,
        string calldata verifierNotes,
        uint64 protectionDuration,
        bytes32[] calldata automaticCountries,
        bytes32[] calldata manualRegistration
    ) external whenNotPaused returns (bool) {
        ComplianceAuthority memory auth = complianceAuthorities[_msgSender()];
        require(auth.isActive, "Not an active authority");

        ComplianceVerificationRequest storage req = complianceRequests[requestId];
        require(req.requestId != 0, "Request not found");
        require(!req.isProcessed, "Request already processed");
        require(isAuthorizedForCountry(_msgSender(), req.countryOfOrigin), "Not authorized for this country");

        // Mark request as processed
        req.isProcessed = true;
        req.isApproved = approved;
        req.verifierNotes = verifierNotes;

        if (approved) {
            // Create or update compliance record for the asset
            ComplianceRecord storage cr = complianceRecords[req.assetId];
            cr.assetId = req.assetId;
            cr.complianceStatus = req.requestedStatus;
            cr.countryOfOrigin = req.countryOfOrigin;
            cr.publicationDate = req.publicationDate;
            cr.registrationAuthority = _msgSender();
            cr.verificationTimestamp = _now();
            cr.complianceEvidenceUri = req.evidenceUri;
            cr.automaticProtectionCount = uint32(automaticCountries.length);
            cr.manualRegistrationCount = uint32(manualRegistration.length);
            cr.protectionDuration = protectionDuration;
            cr.isAnonymousWork = false;
            cr.isCollectiveWork = (req.authorsCount > 1);
            cr.renewalRequired = (protectionDuration > 0);
            cr.nextRenewalDate = (protectionDuration > 0) ? uint64(_now() + protectionDuration) : 0;

            // Update asset’s compliance status and authority verification count
            assetInfo[req.assetId].complianceStatus = req.requestedStatus;
            complianceAuthorities[_msgSender()].verificationCount += 1;

            // Set international protection flags
            for (uint256 i = 0; i < automaticCountries.length; i++) {
                bytes32 c = automaticCountries[i];
                internationalProtection[req.assetId][c] = true;
                automaticProtectionCountries[req.assetId].push(c);
            }
            for (uint256 j = 0; j < manualRegistration.length; j++) {
                manualRegistrationCountries[req.assetId].push(manualRegistration[j]);
            }

            emit ComplianceVerified(req.assetId, req.requestedStatus, _msgSender(), req.countryOfOrigin, protectionDuration, _now());
        }
        return true;
    }

    // Authority updates an asset's compliance status directly (for manual override scenarios)
    function updateComplianceStatus(uint256 assetId, bytes32 newStatus, string calldata evidenceUri) external returns (bool) {
        ComplianceAuthority memory auth = complianceAuthorities[_msgSender()];
        require(auth.isActive, "Not an active authority");

        ComplianceRecord storage cr = complianceRecords[assetId];
        require(cr.assetId != 0, "No compliance record");

        cr.complianceStatus = newStatus;
        cr.complianceEvidenceUri = evidenceUri;
        cr.verificationTimestamp = _now();
        assetInfo[assetId].complianceStatus = newStatus;
        return true;
    }

    function getComplianceRecordA(uint256 assetId) external view returns (
        uint256 assetIdOut,
        bytes32 complianceStatus,
        bytes32 countryOfOrigin,
        uint64  publicationDate,
        address registrationAuthority,
        uint64  verificationTimestamp
    ) {
        ComplianceRecord storage cr = complianceRecords[assetId];
        return (
            cr.assetId,
            cr.complianceStatus,
            cr.countryOfOrigin,
            cr.publicationDate,
            cr.registrationAuthority,
            cr.verificationTimestamp
        );
    }

    function getComplianceRecordB(uint256 assetId) external view returns (
        uint32  automaticProtectionCount,
        uint32  manualRegistrationCount,
        uint64  protectionDuration,
        bool    isAnonymousWork,
        bool    isCollectiveWork,
        bool    renewalRequired,
        uint64  nextRenewalDate
    ) {
        ComplianceRecord storage cr = complianceRecords[assetId];
        return (
            cr.automaticProtectionCount,
            cr.manualRegistrationCount,
            cr.protectionDuration,
            cr.isAnonymousWork,
            cr.isCollectiveWork,
            cr.renewalRequired,
            cr.nextRenewalDate
        );
    }

    function getComplianceRecordEvidence(uint256 assetId) external view returns (string memory) {
        return complianceRecords[assetId].complianceEvidenceUri;
    }

    // Check if an asset is protected in a given country at the current time
    function checkProtectionValidity(uint256 assetId, bytes32 country) public view returns (bool) {
        ComplianceRecord memory cr = complianceRecords[assetId];
        if (cr.assetId == 0) return false;
        if (cr.protectionDuration > 0) {
            uint64 endTs = cr.publicationDate + uint64(cr.protectionDuration);
            if (_now() >= endTs) return false;
        }
        return internationalProtection[assetId][country];
    }

    // Calculate protection duration in seconds for a work, given country and anonymity of the work
    function calculateProtectionDuration(bytes32 country, bytes32 /* workType */, uint64 /* publicationDate */, bool isAnonymous) public view returns (uint64) {
        CountryComplianceRequirements memory req = getCountryRequirements(country);
        uint64 secondsPerYear = 31_536_000; // seconds in 365 days
        if (isAnonymous) {
            return 70 * secondsPerYear;
        }
        return uint64(req.protectionDurationYears) * secondsPerYear;
    }

    function checkRenewalRequirements(uint256 assetId) external view returns (bool renewalRequired, uint64 deadline) {
        ComplianceRecord memory cr = complianceRecords[assetId];
        if (cr.assetId == 0) return (false, 0);
        return (cr.renewalRequired, cr.nextRenewalDate);
    }

    function renewProtection(uint256 assetId, string calldata renewalEvidenceUri) external onlyAssetOwner(assetId) returns (bool) {
        ComplianceRecord storage cr = complianceRecords[assetId];
        require(cr.assetId != 0, "No compliance record");
        require(cr.renewalRequired, "Renewal not required");

        cr.nextRenewalDate = _now() + 31_536_000;  // extend protection by 1 year
        cr.complianceEvidenceUri = renewalEvidenceUri;
        return true;
    }

    function markProtectionExpired(uint256 assetId) external returns (bool) {
        ComplianceAuthority memory auth = complianceAuthorities[_msgSender()];
        require(auth.isActive, "Not an active authority");

        ComplianceRecord storage cr = complianceRecords[assetId];
        require(cr.assetId != 0, "No compliance record");

        bytes32 prevStatus = cr.complianceStatus;
        cr.complianceStatus = _NON_COMPLIANT;
        assetInfo[assetId].complianceStatus = _NON_COMPLIANT;

        emit ProtectionExpired(assetId, prevStatus, _now(), _now());
        return true;
    }

    // Asset owner records manual international protection in additional countries
    function registerInternationalProtection(uint256 assetId, bytes32[] calldata countries, string[] calldata /* evidenceUris */) external onlyAssetOwner(assetId) returns (bool) {
        require(countries.length > 0, "No countries provided");
        for (uint256 i = 0; i < countries.length; i++) {
            bytes32 c = countries[i];
            internationalProtection[assetId][c] = true;
            automaticProtectionCountries[assetId].push(c);
            emit CrossBorderProtectionUpdated(assetId, c, true, _msgSender(), _now());
        }
        return true;
    }

    // (For completeness from Cairo version, not explicitly used in logic here)
    struct InternationalProtectionStatus {
        bytes32[] automaticCountries;
        bytes32[] manualCountries;
    }

    function checkInternationalProtectionStatus(uint256 assetId) public view returns (uint256 automaticCount, uint256 manualCount) {
        ComplianceRecord storage cr = complianceRecords[assetId];
        if (cr.assetId == 0) return (0, 0);
        return (uint256(cr.automaticProtectionCount), uint256(cr.manualRegistrationCount));
    }

    // Validate whether a license can be granted in a certain territory under compliance rules
    function validateLicenseCompliance(uint256 assetId, bytes32 licenseeCountry, bytes32 licenseTerritory, bytes32 usageRights) external view returns (bool) {
        ComplianceRecord memory cr = complianceRecords[assetId];
        if (cr.assetId == 0) return false;

        if (!checkProtectionValidity(assetId, licenseeCountry)) return false;
        if (licenseTerritory != _GLOBAL && !checkProtectionValidity(assetId, licenseTerritory)) return false;

        CountryComplianceRequirements memory req = getCountryRequirements(licenseeCountry);
        if (!req.moralRightsProtected && usageRights == _DERIVATIVE) return false;

        return true;
    }

    // Get any licensing restrictions for a given asset in a target country (e.g., registration required, etc.)
    function getLicensingRestrictions(uint256 assetId, bytes32 targetCountry) public view returns (bytes32[] memory) {
        // If no compliance record, return NO_COMPLIANCE_RECORD restriction
        ComplianceRecord storage cr = complianceRecords[assetId];
        if (cr.assetId == 0) {
            bytes32[] memory out = new bytes32[](1);
            out[0] = _NO_COMPLIANCE_RECORD;
            return out;
        }

        bool noProtection = !checkProtectionValidity(assetId, targetCountry);
        CountryComplianceRequirements memory req = getCountryRequirements(targetCountry);

        bytes32[] memory tmp = new bytes32[](4);
        uint256 n = 0;
        if (noProtection) {
            tmp[n++] = _NO_PROTECTION;
        }
        if (req.noticeRequired) {
            tmp[n++] = _NOTICE_REQUIRED;
        }
        if (!req.moralRightsProtected) {
            tmp[n++] = _NO_MORAL_RIGHTS;
        }
        if (req.registrationRequired && !internationalProtection[assetId][targetCountry]) {
            tmp[n++] = _REGISTRATION_REQUIRED;
        }

        bytes32[] memory out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = tmp[i];
        }
        return out;
    }

    function getComplianceVerificationRequestA(uint256 requestId) external view returns (
        uint256 requestIdOut,
        uint256 assetId,
        address requester,
        bytes32 requestedStatus,
        bytes32 countryOfOrigin,
        uint64  publicationDate
    ) {
        ComplianceVerificationRequest storage r = complianceRequests[requestId];
        return (
            r.requestId,
            r.assetId,
            r.requester,
            r.requestedStatus,
            r.countryOfOrigin,
            r.publicationDate
        );
    }

    function getComplianceVerificationRequestB(uint256 requestId) external view returns (
        bytes32 workType,
        bool    isOriginalWork,
        uint32  authorsCount,
        uint64  requestTimestamp,
        bool    isProcessed,
        bool    isApproved
    ) {
        ComplianceVerificationRequest storage r = complianceRequests[requestId];
        return (
            r.workType,
            r.isOriginalWork,
            r.authorsCount,
            r.requestTimestamp,
            r.isProcessed,
            r.isApproved
        );
    }


    function getComplianceVerificationRequestEvidence(uint256 requestId) external view returns (string memory) {
        return complianceRequests[requestId].evidenceUri;
    }

    function getComplianceVerificationRequestNotes(uint256 requestId) external view returns (string memory) {
        return complianceRequests[requestId].verifierNotes;
    }

    // List asset IDs by compliance status
    function getAssetsByComplianceStatus(bytes32 status) external view returns (uint256[] memory) {
        uint256 total = nextAssetId - 1;
        uint256[] memory tmp = new uint256[](total);
        uint256 n = 0;
        for (uint256 id = 1; id <= total; id++) {
            if (assetInfo[id].assetId != 0 && assetInfo[id].complianceStatus == status) {
                tmp[n++] = id;
            }
        }
        uint256[] memory result = new uint256[](n);
        for (uint256 j = 0; j < n; j++) {
            result[j] = tmp[j];
        }
        return result;
    }

    // List assets requiring protection renewal within a given number of days
    function getExpiringProtections(uint64 withinDays) external view returns (uint256[] memory) {
        uint64 current = _now();
        uint64 threshold = current + withinDays * 86_400;
        uint256 total = nextAssetId - 1;
        uint256[] memory tmp = new uint256[](total);
        uint256 n = 0;
        for (uint256 id = 1; id <= total; id++) {
            ComplianceRecord memory cr = complianceRecords[id];
            if (cr.assetId != 0 && cr.renewalRequired) {
                if (cr.nextRenewalDate <= threshold && cr.nextRenewalDate > current) {
                    tmp[n++] = id;
                }
            }
        }
        uint256[] memory expiringIds = new uint256[](n);
        for (uint256 k = 0; k < n; k++) {
            expiringIds[k] = tmp[k];
        }
        return expiringIds;
    }

    // Check if an asset’s work is in the public domain in a given country (based on protection duration)
    function isWorkInPublicDomain(uint256 assetId, bytes32 /* country */) external view returns (bool) {
        ComplianceRecord memory cr = complianceRecords[assetId];
        if (cr.assetId == 0) return false;
        if (cr.protectionDuration > 0) {
            uint64 endTs = cr.publicationDate + uint64(cr.protectionDuration);
            if (_now() >= endTs) return true;
        }
        return false;
    }

    function getMoralRightsStatus(uint256 assetId, bytes32 country) external view returns (bool) {
        CountryComplianceRequirements memory req = getCountryRequirements(country);
        ComplianceRecord memory cr = complianceRecords[assetId];
        return req.moralRightsProtected && cr.assetId != 0 && checkProtectionValidity(assetId, country);
    }

    function getAuthorityCountries(address authority) external view returns (bytes32[] memory) {
        return authorityCountries[authority];
    }

    function getAutomaticProtectionCountries(uint256 assetId) external view returns (bytes32[] memory) {
        return automaticProtectionCountries[assetId];
    }

    function getManualRegistrationCountries(uint256 assetId) external view returns (bytes32[] memory) {
        return manualRegistrationCountries[assetId];
    }
}
