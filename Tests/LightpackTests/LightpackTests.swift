import XCTest
@testable import Lightpack

final class LightpackLiveTests: XCTestCase {
    var lightpack: Lightpack!

    override func setUp() {
        super.setUp()
        lightpack = Lightpack(apiKey: "your_api_key")
    }

    override func tearDown() {
        lightpack = nil
        super.tearDown()
    }

    func testGetModelsLive() {
        let expectation = XCTestExpectation(description: "Get models from live server")
        
        lightpack.getModels(aliases: nil, bitMax: nil, bitMin: nil, familyIds: nil, modelIds: nil, page: 1, pageSize: 10, parameterIds: nil, quantizationIds: nil, sizeMax: nil, sizeMin: nil, sort: nil) { result in
            switch result {
            case .success((let response, _)):
                XCTAssertFalse(response.models.isEmpty, "Models array should not be empty")
                XCTAssertEqual(response.page, 1, "Page should be 1")
                XCTAssertEqual(response.pageSize, 10, "Page size should be 10")
                XCTAssertGreaterThan(response.total, 0, "Total should be greater than 0")
                
                if let firstModel = response.models.first {
                    XCTAssertFalse(firstModel.modelId.isEmpty, "Model ID should not be empty")
                    XCTAssertFalse(firstModel.title.isEmpty, "Model title should not be empty")
                    // Add more assertions based on your Model structure
                }
            case .failure(let error):
                XCTFail("API call failed with error: \(error)")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10.0)  // Increased timeout for network request
    }

    func testGetModelFamiliesLive() {
        let expectation = XCTestExpectation(description: "Get model families from live server")
        
        lightpack.getModelFamilies(aliases: nil, authors: nil, familyIds: nil, modelParameterIds: nil, page: 1, pageSize: 10, sort: nil, titles: nil, updatedAfter: nil, updatedBefore: nil) { result in
            switch result {
            case .success((let response, _)):
                XCTAssertFalse(response.modelFamilies.isEmpty, "Model families array should not be empty")
                XCTAssertEqual(response.page, 1, "Page should be 1")
                XCTAssertEqual(response.pageSize, 10, "Page size should be 10")
                XCTAssertGreaterThan(response.total, 0, "Total should be greater than 0")
                
                if let firstFamily = response.modelFamilies.first {
                    XCTAssertFalse(firstFamily.familyId.isEmpty, "Family ID should not be empty")
                    XCTAssertFalse(firstFamily.title.isEmpty, "Family title should not be empty")
                    // Add more assertions based on your ModelFamily structure
                }
            case .failure(let error):
                XCTFail("API call failed with error: \(error)")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10.0)  // Increased timeout for network request
    }

    func testGetModelsWithFiltersLive() {
        let expectation = XCTestExpectation(description: "Get models with filters from live server")
        
        lightpack.getModels(aliases: ["qwen2"], bitMax: 32, bitMin: 8, familyIds: nil, modelIds: nil, page: 1, pageSize: 5, parameterIds: nil, quantizationIds: nil, sizeMax: 10.0, sizeMin: 1.0, sort: "size:desc") { result in
            switch result {
            case .success((let response, _)):
                XCTAssertFalse(response.models.isEmpty, "Models array should not be empty")
                XCTAssertEqual(response.page, 1, "Page should be 1")
                XCTAssertEqual(response.pageSize, 5, "Page size should be 5")
                
                for model in response.models {
                    XCTAssertTrue(model.alias.contains("qwen2"), "Model alias should contain 'qwen2'")
                    XCTAssertGreaterThanOrEqual(model.bits, 8, "Model bits should be >= 8")
                    XCTAssertLessThanOrEqual(model.bits, 32, "Model bits should be <= 32")
                    XCTAssertGreaterThanOrEqual(model.size, 1.0, "Model size should be >= 1.0")
                    XCTAssertLessThanOrEqual(model.size, 10.0, "Model size should be <= 10.0")
                }
                
                // Check if models are sorted by size in descending order
                let sizes = response.models.map { $0.size }
                XCTAssertEqual(sizes, sizes.sorted(by: >), "Models should be sorted by size in descending order")
            case .failure(let error):
                XCTFail("API call failed with error: \(error)")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10.0)
    }

    func testGetModelFamiliesWithFiltersLive() {
        let expectation = XCTestExpectation(description: "Get model families with filters from live server")
        
        lightpack.getModelFamilies(aliases: ["qwen2"], authors: nil, familyIds: nil, modelParameterIds: nil, page: 1, pageSize: 5, sort: "title:asc", titles: nil, updatedAfter: nil, updatedBefore: nil) { result in
            switch result {
            case .success((let response, _)):
                XCTAssertFalse(response.modelFamilies.isEmpty, "Model families array should not be empty")
                XCTAssertEqual(response.page, 1, "Page should be 1")
                XCTAssertEqual(response.pageSize, 5, "Page size should be 5")
                
                for family in response.modelFamilies {
                    XCTAssertTrue(family.alias.contains("qwen2"), "Family alias should contain 'qwen2'")
                }
                
                // Check if families are sorted by title in ascending order
                let titles = response.modelFamilies.map { $0.title }
                XCTAssertEqual(titles, titles.sorted(), "Families should be sorted by title in ascending order")
            case .failure(let error):
                XCTFail("API call failed with error: \(error)")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10.0)
    }
}
