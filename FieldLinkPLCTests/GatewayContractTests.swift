import XCTest
@testable import FieldLinkPLC

final class GatewayContractTests: XCTestCase {
    func testDiscoveryReturnsSeededDevicesAfterConnecting() async throws {
        let gateway = SimulatedGatewayClient()
        _ = try await gateway.connect()

        let devices = try await gateway.startDiscovery(profile: .commissioningLab)

        XCTAssertEqual(devices.count, 3)
        XCTAssertTrue(devices.contains(where: { $0.discoveryProtocols.contains(.ethernetIP) }))
        XCTAssertTrue(devices.contains(where: { $0.ipAddress == nil }))
    }

    func testAddressChangeUpdatesDeviceAndAuditTrail() async throws {
        let gateway = SimulatedGatewayClient()
        _ = try await gateway.connect()
        let discovered = try await gateway.startDiscovery(profile: .commissioningLab)
        let device = try XCTUnwrap(discovered.first)
        let request = AddressChangeRequest(
            device: device,
            newIPAddress: "192.168.1.99",
            subnetMask: "255.255.255.0",
            gatewayAddress: "192.168.1.1",
            profileName: "Commissioning Lab",
            makeStatic: true,
            technicianAcknowledged: true
        )

        let event = try await gateway.applyAddressChange(request)
        let refreshed = try await gateway.startDiscovery(profile: .commissioningLab)
        let updated = try XCTUnwrap(refreshed.first(where: { $0.id == device.id }))

        XCTAssertEqual(event.kind, .staticEnabled)
        XCTAssertEqual(updated.ipAddress, "192.168.1.99")
        XCTAssertEqual(updated.addressingState, .staticAddress)
    }

    func testDuplicateAddressIsRejected() async throws {
        let gateway = SimulatedGatewayClient()
        _ = try await gateway.connect()
        let devices = try await gateway.startDiscovery(profile: .commissioningLab)
        let target = try XCTUnwrap(devices.first)
        let alreadyAssignedAddress = try XCTUnwrap(devices.dropFirst().first?.ipAddress)
        let request = AddressChangeRequest(
            device: target,
            newIPAddress: alreadyAssignedAddress,
            subnetMask: "255.255.255.0",
            gatewayAddress: "192.168.1.1",
            profileName: "Commissioning Lab",
            makeStatic: true,
            technicianAcknowledged: true
        )

        do {
            _ = try await gateway.applyAddressChange(request)
            XCTFail("Expected a duplicate address error")
        } catch GatewayClientError.duplicateAddress(let address) {
            XCTAssertEqual(address, alreadyAssignedAddress)
        }
    }

    func testIPv4ValidatorRejectsMalformedAddresses() {
        XCTAssertTrue(IPv4Validator.isValid("192.168.1.253"))
        XCTAssertFalse(IPv4Validator.isValid("192.168.1.256"))
        XCTAssertFalse(IPv4Validator.isValid("192.168.1"))
        XCTAssertFalse(IPv4Validator.isValid("192.168.01.1"))
        XCTAssertFalse(IPv4Validator.isValid(""))
    }

    func testDiscoveryRequiresConnection() async {
        let gateway = SimulatedGatewayClient()

        do {
            _ = try await gateway.startDiscovery(profile: .commissioningLab)
            XCTFail("Expected a not-connected error")
        } catch GatewayClientError.notConnected {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAcknowledgementIsRequiredAndAudited() async throws {
        let gateway = SimulatedGatewayClient()
        _ = try await gateway.connect()
        let discovered = try await gateway.startDiscovery(profile: .commissioningLab)
        let device = try XCTUnwrap(discovered.first)
        let request = AddressChangeRequest(
            device: device,
            newIPAddress: "192.168.1.80",
            subnetMask: "255.255.255.0",
            gatewayAddress: "192.168.1.1",
            profileName: "Commissioning Lab",
            makeStatic: true,
            technicianAcknowledged: false
        )

        do {
            _ = try await gateway.applyAddressChange(request)
            XCTFail("Expected an acknowledgement error")
        } catch GatewayClientError.acknowledgementRequired {
            let events = try await gateway.fetchAuditTrail()
            XCTAssertTrue(events.contains(where: { $0.deviceName == device.name && $0.successful == false }))
        }
    }

    func testInvalidAddressIsRejectedAndAudited() async throws {
        let gateway = SimulatedGatewayClient()
        _ = try await gateway.connect()
        let discovered = try await gateway.startDiscovery(profile: .commissioningLab)
        let device = try XCTUnwrap(discovered.first)
        let request = AddressChangeRequest(
            device: device,
            newIPAddress: "192.168.1.256",
            subnetMask: "255.255.255.0",
            gatewayAddress: "192.168.1.1",
            profileName: "Commissioning Lab",
            makeStatic: true,
            technicianAcknowledged: true
        )

        do {
            _ = try await gateway.applyAddressChange(request)
            XCTFail("Expected an invalid address error")
        } catch GatewayClientError.invalidAddress(let address) {
            XCTAssertEqual(address, "192.168.1.256")
            let events = try await gateway.fetchAuditTrail()
            XCTAssertTrue(events.contains(where: { $0.successful == false && $0.detail.contains("192.168.1.256") }))
        }
    }

    func testDuplicateAddressRejectionIsAudited() async throws {
        let gateway = SimulatedGatewayClient()
        _ = try await gateway.connect()
        let devices = try await gateway.startDiscovery(profile: .commissioningLab)
        let target = try XCTUnwrap(devices.first)
        let alreadyAssignedAddress = try XCTUnwrap(devices.dropFirst().first?.ipAddress)
        let request = AddressChangeRequest(
            device: target,
            newIPAddress: alreadyAssignedAddress,
            subnetMask: "255.255.255.0",
            gatewayAddress: "192.168.1.1",
            profileName: "Commissioning Lab",
            makeStatic: true,
            technicianAcknowledged: true
        )

        do {
            _ = try await gateway.applyAddressChange(request)
            XCTFail("Expected a duplicate address error")
        } catch GatewayClientError.duplicateAddress {
            let events = try await gateway.fetchAuditTrail()
            XCTAssertTrue(events.contains(where: { $0.successful == false && $0.detail.contains(alreadyAssignedAddress) }))
        }
    }

    func testUnconfiguredDeviceNeedsAddressAssignment() {
        let device = SampleGatewayData.devices.first { $0.ipAddress == nil }
        XCTAssertEqual(device?.needsAddressAssignment, true)
        XCTAssertEqual(SampleGatewayData.devices.first?.needsAddressAssignment, false)
    }

    func testNetworkProfileValidation() {
        XCTAssertTrue(NetworkProfile.commissioningLab.isValid)
        var invalid = NetworkProfile.commissioningLab
        invalid.interfaceIPAddress = "10.0.0"
        XCTAssertFalse(invalid.isValid)
    }

    func testListIdentityParserReadsRockwellDevice() {
        var response = Data(count: 24)
        response[0] = 0x63
        response[1] = 0x00

        var item = Data()
        item.append(contentsOf: [0x01, 0x00])
        item.append(contentsOf: [0x00, 0x02, 0x00, 0x00, 192, 168, 1, 10, 0, 0, 0, 0, 0, 0, 0, 0])
        item.append(contentsOf: [0x01, 0x00])
        item.append(contentsOf: [0x0E, 0x00])
        item.append(contentsOf: [0x4D, 0x00])
        item.append(contentsOf: [34, 11])
        item.append(contentsOf: [0x00, 0x00])
        item.append(contentsOf: [0xB2, 0xA0, 0x61, 0xCF])
        let name = Array("CompactLogix".utf8)
        item.append(UInt8(name.count))
        item.append(contentsOf: name)
        item.append(0x00)

        var payload = Data()
        payload.append(contentsOf: [0x01, 0x00])
        payload.append(contentsOf: [0x0C, 0x00])
        payload.append(contentsOf: [UInt8(item.count & 0xff), UInt8(item.count >> 8)])
        payload.append(item)

        response[2] = UInt8(payload.count & 0xff)
        response[3] = UInt8(payload.count >> 8)
        response.append(payload)

        let device = EtherNetIPListIdentity.parse(response: response, sourceAddress: "192.168.1.10")
        XCTAssertEqual(device?.vendor, "Rockwell Automation")
        XCTAssertEqual(device?.name, "CompactLogix")
        XCTAssertEqual(device?.ipAddress, "192.168.1.10")
        XCTAssertEqual(device?.discoveryProtocols, [.ethernetIP])
    }

    func testPlantEthernetIgnoresWiFiAndCellularNames() {
        XCTAssertFalse(PlantEthernet.isCandidateName("en0"))
        XCTAssertFalse(PlantEthernet.isCandidateName("pdp_ip0"))
        XCTAssertFalse(PlantEthernet.isCandidateName("awdl0"))
        XCTAssertTrue(PlantEthernet.isCandidateName("en2"))
        XCTAssertTrue(PlantEthernet.isCandidateName("en1"))
    }

    func testLiveDiscoveryRejectsAddressWrites() async throws {
        let gateway = LocalNetworkGatewayClient()
        do {
            _ = try await gateway.applyAddressChange(
                AddressChangeRequest(
                    device: SampleGatewayData.devices[0],
                    newIPAddress: "192.168.1.99",
                    subnetMask: "255.255.255.0",
                    gatewayAddress: "192.168.1.1",
                    profileName: "Commissioning Lab",
                    makeStatic: true,
                    technicianAcknowledged: true
                )
            )
            XCTFail("Expected live discovery to refuse writes")
        } catch GatewayClientError.notConnected {
            // Not connected yet is also a refusal to write.
        } catch GatewayClientError.unsupportedOperation {
            // Expected after a successful connect.
        }
    }
}
