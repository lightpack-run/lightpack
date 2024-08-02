<p align="center">
  <img src="https://lightpack.run/lightpack-text.svg" alt="Lightpack Logo" height="200"/>
</p>

<p align="center">
  <img src="https://img.shields.io/github/v/release/lightpack-run/lightpack" alt="GitHub release (latest by date)"/>
  <img src="https://img.shields.io/badge/Swift-5.5+-orange.svg" alt="Swift"/>
  <img src="https://img.shields.io/badge/Platforms-iOS%2014+%20|%20macOS%2012+%20|%20tvOS%2014+%20|%20watchOS%206+-blue.svg" alt="Platforms"/>
  <img src="https://img.shields.io/badge/Swift_Package_Manager-compatible-brightgreen.svg" alt="Swift Package Manager"/>
  <img src="https://img.shields.io/badge/Package%20Size-106%20KB-brightgreen" alt="Package Size"/>
  <img src="https://img.shields.io/github/stars/lightpack-run/lightpack" alt="GitHub stars"/>
</p>

Run **Llama 3.1** and **Gemma 2** in your app for free. Lightpack lets you chat with your favorite AI models on-device in 3 lines of code. The Swift package is **open-sourced**, supports **offline**, and preserves **privacy** by keeping conversations local.

## Installation

### For App Developers

To add Lightpack to your Xcode project:

1. In Xcode, select "File" → "Add Packages..."
2. In the search bar, enter the URL of the Lightpack repository: `https://github.com/lightpack-run/lightpack.git`
3. Choose the version rule you want to follow (e.g., "Up to Next Major" version)
4. Click "Add Package"

After installation, you can import Lightpack in your Swift files:

```swift
import Lightpack
```

### For Swift Package Developers

If you're developing a Swift package, add the following line to your `Package.swift` file's dependencies:

```swift
.package(url: "https://github.com/lightpack-run/lightpack.git", from: "0.0.1")
```

Then, include "Lightpack" as a dependency for your target:

```swift
.target(name: "YourTarget", dependencies: ["Lightpack"]),
```

You can then import Lightpack in your Swift files:

```swift
import Lightpack
```

## Getting Started

### Obtaining an API Key

Before you can use Lightpack, you'll need to obtain an API key. Follow these steps:

1. Visit [https://lightpack.run](https://lightpack.run)
2. Sign up for an account if you haven't already
3. Go to [API Keys](https://lightpack.run/project-api-keys)
4. Click on "Create New" to generate a new API key
5. Copy the generated API key

Once you have your API key, you can initialize Lightpack in your code like this:

```swift
let lightpack = Lightpack(apiKey: "your_api_key")
```

Replace `"your_api_key"` with the actual API key you copied from the Lightpack website.

**Important**: Keep your API key secure and never share it publicly or commit it to version control systems.

### Using Lightpack

Here's a simple example to get you started with Lightpack:

[The rest of the Getting Started section remains unchanged]

```swift
import Lightpack

let lightpack = Lightpack(apiKey: "your_api_key")

do {
    let messages = [LPChatMessage(role: .user, content: "Why is the sky blue?")]
    
    var response = ""
    try await lightpack.chatModel("23a77013-fe73-4f26-9ab2-33d315a71924", messages: messages) { token in
        response += token
        print("Received token: \(token)")
    }
    
    print("Full response: \(response)")
} catch {
    print("Error: \(error)")
}
```

This example initializes Lightpack with your API key and then uses the `chatModel` function to interact with the default model.

## SwiftUI Example

Here's a basic SwiftUI example that demonstrates how to use Lightpack in a chat interface:

```swift
import SwiftUI
import Lightpack

struct ChatView: View {
    @StateObject private var lightpack = Lightpack(apiKey: "your_api_key")
    @State private var userInput = ""
    @State private var chatMessages: [LPChatMessage] = []
    @State private var isLoading = false

    var body: some View {
        VStack {
            ScrollView {
                ForEach(chatMessages, id: \.content) { message in
                    MessageView(message: message)
                }
            }
            
            HStack {
                TextField("Type a message", text: $userInput)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                Button("Send") {
                    sendMessage()
                }
                .disabled(userInput.isEmpty || isLoading)
            }
            .padding()
        }
    }

    func sendMessage() {
        let userMessage = LPChatMessage(role: .user, content: userInput)
        chatMessages.append(userMessage)
        isLoading = true
        
        Task {
            do {
                var assistantResponse = ""
                try await lightpack.chatModel(messages: chatMessages) { token in
                    assistantResponse += token
                }
                
                let assistantMessage = LPChatMessage(role: .assistant, content: assistantResponse)
                chatMessages.append(assistantMessage)
                isLoading = false
                userInput = ""
            } catch {
                print("Error: \(error)")
                isLoading = false
            }
        }
    }
}

struct MessageView: View {
    let message: LPChatMessage
    
    var body: some View {
        HStack {
            if message.role == .user {
                Spacer()
            }
            Text(message.content)
                .padding()
                .background(message.role == .user ? Color.blue : Color.gray)
                .foregroundColor(.white)
                .cornerRadius(10)
            if message.role == .assistant {
                Spacer()
            }
        }
        .padding(.horizontal)
    }
}
```

This SwiftUI example creates a simple chat interface where:

1. Users can type messages and send them to the AI model.
2. The AI model's responses are displayed in the chat.
3. Messages are visually differentiated between user and AI.
4. A loading state is managed to prevent sending multiple messages while waiting for a response.

Remember to replace "your_api_key" with your actual Lightpack API key.

## Available Model Families

Lightpack supports various model families. Here's an overview of the available families:

| Family | Author | Parameters | License | Paper | Family ID |
|--------|--------|------------|---------|-------|-----------|
| Llama 3.1 | Meta | 8B | [Custom](https://github.com/meta-llama/llama3?tab=License-1-ov-file) | [AI Meta](https://ai.meta.com/llama/) | 3dbcfe36-17fc-45b8-acb6-b3af2c320431 |
| Llama 3 | Meta | 8B | [Custom](https://github.com/meta-llama/llama3?tab=License-1-ov-file) | [AI Meta](https://ai.meta.com/llama/) | 4dd3eef8-c83e-4338-b7b9-17a9ae2a557e |
| Gemma 2 | Google | 9B | [Custom](https://github.com/google-deepmind/gemma/blob/main/LICENSE) | [DeepMind](https://www.deepmind.com/research/publications/gemma-2-learning-and-reasoning-at-scale) | 50be08ec-d6a1-45c8-8c6f-efa34ee9ba17 |
| Gemma 1 | Google | 2B | [Custom](https://github.com/google-deepmind/gemma/blob/main/LICENSE) | [DeepMind](https://storage.googleapis.com/deepmind-media/gemma/gemma-report.pdf) | 4464c014-d2ed-4be6-a8c5-0cf86c6c87ab |
| Phi 3 | Microsoft | Mini-4K | [Custom](https://huggingface.co/microsoft/Phi-3-mini-4k-instruct) | [arXiv](https://arxiv.org/abs/2404.14219) | 7d64ec31-667f-45bb-8d6e-fdb0dffe7fe4 |
| Mistral v0.3 | Mistral | 7B | [Apache 2.0](https://github.com/mistralai/mistral-inference?tab=Apache-2.0-1-ov-file) | [Mistral Docs](https://docs.mistral.ai/) | 3486641f-27ee-4eee-85be-68a1826873ca |
| Qwen2 | Alibaba | 0.5B, 1.5B, 7B | [Apache 2.0](https://huggingface.co/datasets/choosealicense/licenses/blob/main/markdown/apache-2.0.md) | [arXiv](https://arxiv.org/abs/2407.10671) | a9a97695-2573-4d12-99e0-371aae7ac009 |
| TinyLlama | Zhang Peiyuan | 1.1B | [Apache 2.0](https://github.com/jzhang38/TinyLlama?tab=Apache-2.0-1-ov-file) | [arXiv](https://arxiv.org/pdf/2401.02385) | 75f98968-be6d-48c8-9b32-e76598e262be |

For more detailed information about each model, including available versions and specific capabilities, please refer to [Lightpack models](https://lightpack.run/models).

## Typical Workflow and Function Availability

Lightpack is designed to be flexible and user-friendly. Here's an overview of the typical workflow:

### Basic Operation Steps

1. **Get the model ID**: You can use [`getModels()`](#get-models) to show users a list of models to select from. If no model ID is provided, we use a default model.
2. **Download the model**: Use [`downloadModel(modelId)`](#download-a-model) to download the selected model.
3. **Load the model**: Use [`loadModel(modelId)`](#load-a-model) to load the model into the chat context window.
4. **Chat with the model**: Use [`chatModel(modelId, messages)`](#chat-with-a-model) to interact with the loaded model.

### Simplified Usage

For convenience, you can skip directly to using [`chatModel()`](#chat-with-a-model). If any prerequisite steps (like downloading or loading) haven't been completed, Lightpack will handle them automatically. This means you can provide a seamless experience by just calling [`chatModel()`](#chat-with-a-model), and we'll take care of using the default model ID, downloading, loading, and chat setup all at once.

However, for the best user experience, especially with larger models, we recommend handling these steps explicitly in your app's UI to provide progress feedback to the user.

Online vs. Offline Functionality
Here's a breakdown of which functions require an internet connection and which can work offline:
Online-only Functions:

[`downloadModel(modelId)`](#download-a-model)
[`getModels()`](#get-models)
[`getModelFamilies()`](#get-model-families)
[`resumeDownloadModel()`](#resume-a-model-download)

Offline-capable Functions (if model is already downloaded or downloading):

[`loadModel(modelId)`](#load-a-model)
[`chatModel()`](#chat-with-a-model)
[`pauseDownloadModel()`](#pause-a-model-download)
[`cancelDownloadModel()`](#cancel-a-model-download)
[`removeModels()`](#remove-models)
[`clearChat()`](#clear-chat-history)

Note that while chatModel() can work offline with a downloaded model, it will automatically attempt to download the model if it's not available locally, which requires an internet connection.

## Available Functions with Code Snippets

Here are quick code snippets for each of the core functions provided by Lightpack:

### Model Information

#### Get models

```swift
lightpack.getModels(
    bitMax: 6,
    bitMin: 2,
    familyIds: ["3dbcfe36-17fc-45b8-acb6-b3af2c320431", "50be08ec-d6a1-45c8-8c6f-efa34ee9ba17"],
    modelIds: nil,
    page: 1,
    pageSize: 10,
    parameterIds: ["1.1B", "7B"],
    quantizationIds: ["q4_0", "q5_1"],
    sizeMax: 5,  // 5 GB
    sizeMin: 0.5,   // 500 MB
    sort: "size:desc"
) { result in
    switch result {
    case .success((let response, let updatedModelIds)):
        print("Fetched \(response.models.count) models")
        print("Updated model IDs: \(updatedModelIds)")
        response.models.forEach { model in
            print("Model: \(model.title), Size: \(model.size) bytes")
        }
    case .failure(let error):
        print("Error fetching models: \(error)")
    }
}
```

#### Get model families

```swift
lightpack.getModelFamilies(
    familyIds: ["3dbcfe36-17fc-45b8-acb6-b3af2c320431", "50be08ec-d6a1-45c8-8c6f-efa34ee9ba17"],
    modelParameterIds: ["1.1B", "7B"],
    page: 1,
    pageSize: 5,
    sort: "title:asc"
) { result in
    switch result {
    case .success((let response, let updatedFamilyIds)):
        print("Fetched \(response.modelFamilies.count) model families")
        print("Updated family IDs: \(updatedFamilyIds)")
        response.modelFamilies.forEach { family in
            print("Family: \(family.title), Parameters: \(family.modelParameterIds)")
        }
    case .failure(let error):
        print("Error fetching model families: \(error)")
    }
}
```

### Model Management

_Replace the example `"23a77013-fe73-4f26-9ab2-33d315a71924"` with your actual model ID_

#### Download a model

```swift
do {
    try await lightpack.downloadModel("23a77013-fe73-4f26-9ab2-33d315a71924")
    print("Model downloaded successfully")
} catch {
    print("Error downloading model: \(error)")
}
```

#### Pause a model download

```swift
do {
    try await lightpack.pauseDownloadModel("23a77013-fe73-4f26-9ab2-33d315a71924")
    print("Model download paused")
} catch {
    print("Error pausing download: \(error)")
}
```

#### Resume a model download

```swift
do {
    try await lightpack.resumeDownloadModel("23a77013-fe73-4f26-9ab2-33d315a71924")
    print("Model download resumed")
} catch {
    print("Error resuming download: \(error)")
}
```

#### Cancel a model download

```swift
do {
    try await lightpack.cancelDownloadModel("23a77013-fe73-4f26-9ab2-33d315a71924")
    print("Model download cancelled")
} catch {
    print("Error cancelling download: \(error)")
}
```

#### Remove models

```swift
do {
    // Remove specific models
    try await lightpack.removeModels(modelIds: ["model_id_1", "model_id_2"], removeAll: false)
    
    // Or remove all models
    // try await lightpack.removeModels(removeAll: true)
    
    print("Models removed successfully")
} catch {
    print("Error removing models: \(error)")
}
```

#### Load a model

```swift
do {
    try await lightpack.loadModel("23a77013-fe73-4f26-9ab2-33d315a71924", setActive: true)
    print("Model loaded and set as active")
} catch {
    print("Error loading model: \(error)")
}
```

### Chat Interaction

#### Chat with a model

```swift
do {
    let messages = [
        LPChatMessage(role: .user, content: "Why is water blue?")
    ]
    
    try await lightpack.chatModel("23a77013-fe73-4f26-9ab2-33d315a71924", messages: messages) { token in
        print(token)
    }
} catch {
    print("Error in chat: \(error)")
}
```

#### Clear chat history

```swift
do {
    try await lightpack.clearChat()
    print("Chat history cleared")
} catch {
    print("Error clearing chat: \(error)")
}
```

### Check for Model Updates

Lightpack provides a way to check for model updates using the `getModels` or `getModelFamilies` functions. If any updated models are returned, you can use this information to prompt users to update their local models or automatically update them in the background.

Here's how you can check for model updates:

```swift
func checkForModelUpdates() {
    lightpack.getModels(modelIds["23a77013-fe73-4f26-9ab2-33d315a71924"]) { result in
        switch result {
        case .success((let response, let updatedModelIds)):
            if !updatedModelIds.isEmpty {
                print("Updates available for \(updatedModelIds.count) models")
                // Prompt user to update or automatically update
                for modelId in updatedModelIds {
                    updateModel(modelId: modelId)
                }
            } else {
                print("All models are up to date")
            }
        case .failure(let error):
            print("Error checking for updates: \(error)")
        }
    }
}

func updateModel(modelId: String) {
    Task {
        do {
            try await lightpack.downloadModel(modelId)
            print("Model \(modelId) updated successfully")
        } catch {
            print("Error updating model \(modelId): \(error)")
        }
    }
}
```

In this example:

1. We use the `getModels` function to fetch the latest model information.
2. We check the `updatedModelIds` array in the result to see if any models have updates available.
3. If updates are available, we either prompt the user or automatically update the models using the `downloadModel` function.

You can call the `checkForModelUpdates` function periodically (e.g., once a day or when your app starts) to ensure your local models are up to date.

Remember to handle the update process gracefully, especially for large model files, by showing progress to the user and allowing them to pause or cancel the update if needed.

[Previous content remains unchanged]

## Public Variables

Lightpack exposes several public variables that provide information about the current state of models and families. These variables are marked with `@Published` and can be observed in SwiftUI views or used in UIKit applications.

### Available Variables

- `models: [String: LPModel]`
  A dictionary of all models, keyed by their model IDs. Each `LPModel` contains information about a specific model, including its status, size, and other metadata.

- `families: [String: LPModelFamily]`
  A dictionary of all model families, keyed by their family IDs. Each `LPModelFamily` contains information about a group of related models.

- `loadedModel: LPModel?`
  The currently loaded model, if any. This will be `nil` if no model is currently loaded.

- `totalModelSize: Float`
  The total size of all downloaded models in bytes.

### Accessing Public Variables

You can access these variables directly from your Lightpack instance. Here's an example of how to use them:

```swift
let lightpack = Lightpack(apiKey: "your_api_key")

// Print information about all models
for (modelId, model) in lightpack.models {
    print("Model ID: \(modelId)")
    print("Model Title: \(model.title)")
    print("Model Status: \(model.status)")
    print("Model Size: \(model.size) bytes")
    print("---")
}

// Print information about the currently loaded model
if let loadedModel = lightpack.loadedModel {
    print("Loaded Model: \(loadedModel.title)")
} else {
    print("No model currently loaded")
}

// Print the total size of all downloaded models
print("Total size of downloaded models: \(lightpack.totalModelSize) bytes")
```

### Observing Changes in SwiftUI

In SwiftUI, you can observe changes to these variables by creating a `@StateObject` of your Lightpack instance:

```swift
struct ContentView: View {
    @StateObject var lightpack = Lightpack(apiKey: "your_api_key")

    var body: some View {
        VStack {
            Text("Number of models: \(lightpack.models.count)")
            Text("Number of families: \(lightpack.families.count)")
            if let loadedModel = lightpack.loadedModel {
                Text("Loaded model: \(loadedModel.title)")
            } else {
                Text("No model loaded")
            }
            Text("Total model size: \(lightpack.totalModelSize) bytes")
        }
    }
}
```

This way, your view will automatically update whenever these variables change.

For more detailed information on each function, please refer to the inline documentation or the full API reference.

## Contributing

We welcome contributions to Lightpack! If you'd like to contribute, please follow these steps:

1. Fork the repository on GitHub.
2. Create a new branch for your feature or bug fix.
3. Make your changes and commit them with clear, descriptive commit messages.
4. Push your changes to your fork.
5. Create a pull request from your fork to the main Lightpack repository.

To create a pull request:
1. Navigate to the main page of the Lightpack repository.
2. Click on "Pull requests" and then on the "New pull request" button.
3. Select your fork and the branch containing your changes.
4. Fill out the pull request template with a clear title and description of your changes.
5. Click "Create pull request".

We'll review your pull request and provide feedback as soon as possible. Thank you for your contribution!

## Bugs

If you encounter a bug while using Lightpack, we appreciate your help in reporting it. Please follow these steps to submit a bug report:

1. Go to the [Issues page](https://github.com/lightpack-run/lightpack/issues) of the Lightpack repository on GitHub.
2. Click on the "New issue" button.
3. Choose the "Bug report" template if available, or start a blank issue.
4. Provide a clear and descriptive title for the issue.
5. In the body of the issue, please include:
   - A detailed description of the bug
   - Steps to reproduce the issue
   - What you expected to happen
   - What actually happened
   - Your environment (OS version, Xcode version, Lightpack version, etc.)
   - Any relevant code snippets or screenshots
6. Click "Submit new issue" when you're done.

Before submitting a new bug report, please search the existing issues to see if someone has already reported the problem. If you find a similar issue, you can add additional information in the comments.

We appreciate your help in improving Lightpack!

## Model Licenses

Please see the model licenses in [Available Model Families](#available-model-families) or [Lightpack Models](https://lightpack.run/models). Different models may have different licensing terms, so it's important to review the specific license for each model you intend to use.

## Support

If you need assistance or have any questions about Lightpack, please don't hesitate to reach out. You can contact the founders directly at [founders@lightpack.run](mailto:founders@lightpack.run).

We strive to respond to all inquiries as quickly as possible and appreciate your feedback and questions.

We hope you find Lightpack useful for your AI-powered Swift applications! If you have any questions or run into any issues, please don't hesitate to reach out.
