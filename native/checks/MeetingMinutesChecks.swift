import Foundation

func meetingMinutesChecks() throws -> [String] {
    let transcript = "参会者甲：建议先试行两周。\n参会者乙：好，周五前我会发测试清单。\n参会者甲：我们先核对完成情况再决定是否扩大。"
    let request = try MeetingMinutes.request(
        title: "试运行安排",
        finalTranscript: transcript,
        notes: "重点：试运行周期；人名以确认词表为准。",
        references: ["参考资料：试运行检查清单"]
    )
    guard let inputData = request.input.data(using: .utf8),
          let input = try JSONSerialization.jsonObject(with: inputData) as? [String: Any],
          input["final_transcript"] as? String == transcript,
          input["notes_for_focus_and_terms"] as? String == "重点：试运行周期；人名以确认词表为准。",
          input["reference_material"] as? [String] == ["参考资料：试运行检查清单"] else {
        throw MeetingMinutesError.invalidResponse
    }

    let response = """
    {"overview":"会议讨论了试运行周期和后续检查安排。","topics_and_conclusions":["先观察两周试运行情况，再决定是否扩大。"],"decisions":[],"action_items":[{"text":"发送测试清单","owner":"参会者乙","due":"周五前","evidence_quote":"周五前我会发测试清单。"}],"open_questions":["是否扩大试运行范围尚待评估。"],"key_quotes":["周五前我会发测试清单。"]}
    """
    let markdown = try MeetingMinutes.validateAndRender(response, title: "试运行安排", finalTranscript: transcript)
    let expectedHeadings = MeetingMinutes.headings.map { "## " + $0 }
    let actualHeadings = markdown.components(separatedBy: .newlines).filter { $0.hasPrefix("## ") }
    guard actualHeadings == expectedHeadings,
          markdown.contains("- 发送测试清单｜负责人：参会者乙｜时间：周五前"),
          markdown.contains("“周五前我会发测试清单。”"),
          !markdown.contains("参考资料"), !markdown.contains("我的笔记"), !markdown.contains("会中笔记") else {
        throw MeetingMinutesError.invalidResponse
    }

    let invalidQuote = response.replacingOccurrences(of: "周五前我会发测试清单。", with: "周五我会发送测试清单。")
    guard rejects(invalidQuote, transcript: transcript) else { throw MeetingMinutesError.invalidResponse }

    let proposalAsDecision = """
    {"overview":"会议讨论了试运行建议。","topics_and_conclusions":["建议先试行两周。"],"decisions":[{"text":"决定试行两周","evidence_quote":"建议先试行两周。"}],"action_items":[],"open_questions":[],"key_quotes":[]}
    """
    guard rejects(proposalAsDecision, transcript: transcript) else { throw MeetingMinutesError.invalidResponse }

    let extraSection = response.replacingOccurrences(of: "\"open_questions\":", with: "\"private_notes\":\"不应追加\",\"open_questions\":")
    guard rejects(extraSection, transcript: transcript) else { throw MeetingMinutesError.invalidResponse }
    let headingInjection = response.replacingOccurrences(of: "会议讨论了试运行周期和后续检查安排。", with: "会议讨论了试运行周期。\n## 我的笔记")
    guard rejects(headingInjection, transcript: transcript) else { throw MeetingMinutesError.invalidResponse }
    let company = "我们常规邀请的是甲公司和乙公司。他来过好多次，北京这次还在沟通。"
    let falsePayment = #"{"overview":"常规支持两种支付渠道。","topics_and_conclusions":[],"decisions":[],"action_items":[],"open_questions":[],"key_quotes":[]}"#
    let falseRefusal = #"{"overview":"对方拒绝合作，双方存在分歧。","topics_and_conclusions":[],"decisions":[],"action_items":[],"open_questions":[],"key_quotes":[]}"#
    let negativeDecision = #"{"overview":"会议讨论活动安排。","topics_and_conclusions":[],"decisions":[{"text":"拒绝参加活动","evidence_quote":"不。"}],"action_items":[],"open_questions":[],"key_quotes":[]}"#
    guard rejects(falsePayment, transcript: company),
          rejects(falseRefusal, transcript: "不。好的，好的，没问题。谢谢大家。"),
          rejects(negativeDecision, transcript: "不。") else { throw MeetingMinutesError.invalidResponse }
    let payment = "我们支持信用卡支付。"
    _ = try MeetingMinutes.validateAndRender(falsePayment.replacingOccurrences(of: "常规支持两种支付渠道。", with: payment), title: "支付讨论", finalTranscript: payment)
    guard !MeetingMinutes.evidenceEligible(["final": true, "text": "不。"]),
          !MeetingMinutes.evidenceEligible(["final": false, "text": company]),
          !MeetingMinutes.evidenceEligible(["final": true, "text": company, "quality_flags": ["audio_corrupt"]]),
          !MeetingMinutes.evidenceEligible(["final": true, "text": "本次会议讨论的是活动参加情况以及安排。ちちち。反复内容。にとる。"]),
          MeetingMinutes.evidenceEligible(["final": true, "text": "不参加这次活动。"]),
          MeetingMinutes.evidenceEligible(["final": true, "text": "こんにちは。次の会議では企業参加状況及び共同宣伝計画について確認します。"]),
          MeetingMinutes.evidenceEligible(["final": true, "text": company]) else { throw MeetingMinutesError.invalidResponse }
    return ["minutes_request_separates_evidence_and_background", "minutes_valid_json_renders_fixed_template", "minutes_rejects_nonverbatim_quote", "minutes_rejects_proposal_as_decision", "minutes_rejects_extra_output_fields", "minutes_rejects_heading_injection", "minutes_rejects_unsupported_payment_and_refusal", "minutes_filters_unreliable_evidence_preserving_explicit_negation_and_japanese"]
}

private func rejects(_ response: String, transcript: String) -> Bool {
    do { _ = try MeetingMinutes.validateAndRender(response, title: "测试", finalTranscript: transcript); return false }
    catch { return true }
}
