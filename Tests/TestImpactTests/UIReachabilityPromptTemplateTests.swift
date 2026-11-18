// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

private func templateCase(_ id: String = "case") -> UIReachabilityCase {
    let function = UIReachabilityInput.Fragment(name: "save", region: .init(path: "App/Save.swift", startLine: 1, endLine: 2),
        source: "func save() { /* {{ expected }} & < > */ }", calls: ["persist"], scope: "Store")
    let test = UIReachabilityInput.Fragment(name: "testSave", region: .init(path: "Tests/UI.swift", startLine: 1, endLine: 2),
        source: "func testSave() { app.buttons[\"Save\"].tap() }", calls: ["tap"], scope: "Suite")
    return .init(id: id, input: .init(revision: String(repeating: "a", count: 40), testIdentifier: "UI/Suite/testSave()",
        function: function, test: test, context: [function], contextKind: "fixture", limitations: ["limited evidence"]),
        expected: true, evidenceKind: .sourceReview, evidence: "PRIVATE_LABEL_SENTINEL")
}

@Test func aiDefaultStencilPreservesBuiltInPromptAndLiteralSource() throws {
    let item = templateCase()
    let templates = UIReachabilityPromptTemplates()
    try templates.validate()
    let rendered = try templates.render(item.input)
    #expect(rendered.instructions == UIReachabilityPrompt.instructions)
    #expect(rendered.prompt == (try UIReachabilityPrompt.render(item.input)))
    #expect(rendered.prompt.contains("{{ expected }} & < >"))
    #expect(try templates.version == UIReachabilityPrompt.version)
}

@Test func aiStencilExposesSourcePathsLoopsAndJSONWithoutLabels() throws {
    let templates = UIReachabilityPromptTemplates(instructionsTemplate: "{{ outputContract }}", promptTemplate: """
    {{ function.region.path }}:{{ function.region.startLine }}
    {% for fragment in context %}{{ fragment.scope }}.{{ fragment.name }}{% endfor %}
    {% if limitations %}{{ limitations|json }}{% endif %}
    {{ expected|default:"NO_LABEL" }} {{ evidence|default:"NO_EVIDENCE" }} {{ confidenceThreshold|default:"NO_THRESHOLD" }}
    {{ function.source|required }}
    {{ input.test.source|json }}
    """)
    try templates.validate()
    let rendered = try templates.render(templateCase().input)
    #expect(rendered.prompt.contains("App/Save.swift:1"))
    #expect(rendered.prompt.contains("Store.save"))
    #expect(rendered.prompt.contains("[\"limited evidence\"]"))
    #expect(rendered.prompt.contains("NO_LABEL NO_EVIDENCE NO_THRESHOLD"))
    #expect(!rendered.prompt.contains("PRIVATE_LABEL_SENTINEL"))
    #expect(rendered.prompt.contains("{{ expected }} & < >"))
    #expect(rendered.instructions == UIReachabilityPromptTemplates.outputContract)
}

@Test func aiStencilConfigurationAndRenderingHaveDistinctDigests() throws {
    let templates = UIReachabilityPromptTemplates(promptTemplate: "{{ test.source }}")
    var editedTemplates = templates
    editedTemplates.promptTemplate += " "
    #expect(try templates.digest != editedTemplates.digest)
    #expect(try templates.version.hasPrefix("custom-stencil-v1:"))
    var item = templateCase()
    let first = try templates.render(item.input)
    item.input.test.source += " // changed"
    #expect(first.digest != (try templates.render(item.input).digest))
    #expect(try UIReachabilityPromptTemplates(promptTemplate: "{{ test.source }}").digest == templates.digest)
}

@Test func aiStencilVersionsAndArchivesTrackBuiltInValues() throws {
    let templates = UIReachabilityPromptTemplates(instructionsTemplate: "{{ defaultInstructions }}\n{{ outputContract }}")
    let input = templateCase().input
    let original = try templates.render(input)
    for changeInstructions in [true, false] {
        var changed = templates
        if changeInstructions { changed.builtInInstructions = "Different release's built-in instructions" }
        else { changed.builtInOutputContract = "Different release's output contract" }
        let rendered = try changed.render(input)
        #expect(rendered.instructions != original.instructions)
        #expect(try changed.digest != templates.digest)
        #expect(try changed.version != templates.version)
        // Decoding must preserve the recorded values, not substitute this
        // process's current defaults and silently change the rendered prompt.
        let saved = try JSONDecoder().decode(UIReachabilityPromptTemplates.self, from: JSONEncoder().encode(changed))
        #expect(try saved.render(input).instructions == rendered.instructions)
        #expect(try saved.render(input).digest == rendered.digest)
        #expect(try saved.digest == changed.digest)
        #expect(try saved.version == changed.version)
    }
}

@Test func aiStencilLegacyConfigurationsStillDecode() throws {
    let data = Data(#"{"instructionsTemplate":"{{ defaultInstructions }}","promptTemplate":"{{ outputContract }}"}"#.utf8)
    let legacy = try JSONDecoder().decode(UIReachabilityPromptTemplates.self, from: data)
    let rendered = try legacy.render(templateCase().input)
    #expect(rendered.instructions == UIReachabilityPrompt.instructions)
    #expect(rendered.prompt == UIReachabilityPromptTemplates.outputContract)
}

@Test func aiStencilErrorsFailBeforeAnyModelCallsIncludingLaterRows() async throws {
    var second = templateCase("second")
    second.input.function.name = "second"
    let dataset = UIReachabilityDataset(cases: [templateCase(), second])
    for source in ["{% if test %}", "{{ function.source|missingFilter }}", "{{ nonexistent|required }}",
                   "{% if function.name == 'second' %}{{ missing|required }}{% else %}valid{% endif %}",
                   "{% include 'untracked.stencil' %}", "{{ nonexistent }}", " "] {
        var calls = 0
        await #expect(throws: (any Error).self) {
            try await UIReachabilityEvaluation.run(dataset, provider: "fake", availability: "test",
                templates: .init(promptTemplate: source)) { _, _ in
                calls += 1
                return .init(confidencePercent: 75, reason: "should not run")
            }
        }
        #expect(calls == 0)
    }
}

@Test func aiStencilSizeFailuresRemainRetainedAbstentions() async throws {
    let dataset = UIReachabilityDataset(cases: [templateCase()])
    for templates in [
        UIReachabilityPromptTemplates(promptTemplate: String(repeating: "x", count: UIReachabilityPromptTemplates.maximumPromptBytes + 1)),
        UIReachabilityPromptTemplates(instructionsTemplate: String(repeating: "x", count: UIReachabilityPromptTemplates.maximumInstructionsBytes + 1))
    ] {
        var calls = 0
        let report = try await UIReachabilityEvaluation.run(dataset, provider: "fake", availability: "test", templates: templates) { _, _ in
            calls += 1; return .init(confidencePercent: 75, reason: "should not run")
        }
        #expect(calls == 0)
        #expect(report.rows[0].prediction.error != nil && report.rows[0].renderedPromptDigest == nil)
        #expect(report.selection?.decisions[0].retainedForUnknown == true)
    }
}

@Test func aiStencilReportsIdentifyExactlyThePromptsPassedToProvider() async throws {
    let templates = UIReachabilityPromptTemplates(instructionsTemplate: "{{ outputContract }}",
        promptTemplate: "Target: {{ function.name }}\n{{ inputJSON }}")
    let dataset = UIReachabilityDataset(cases: [templateCase()])
    var observed: UIReachabilityPromptTemplates.Rendered?
    let report = try await UIReachabilityEvaluation.run(dataset, provider: "fake", availability: "test", templates: templates) { _, rendered in
        observed = rendered
        return .init(confidencePercent: 75, reason: "fixture")
    }
    #expect(report.rows[0].renderedPromptDigest == observed?.digest)
    #expect(report.promptTemplates?.promptTemplate == templates.promptTemplate)
    #expect(report.templateDigest == (try templates.digest))
    #expect(report.promptVersion == (try templates.version))
    #expect(report.selection?.templateDigest == report.templateDigest)
    let saved = try JSONDecoder().decode(UIReachabilityEvaluation.self, from: JSONEncoder().encode(report))
    #expect(saved.promptTemplates?.instructionsTemplate == templates.instructionsTemplate)
    #expect(saved.rows[0].renderedPromptDigest == observed?.digest)
}
