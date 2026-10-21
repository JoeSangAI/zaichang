import Foundation

// User-selected terms are optional and are sent only with authorized cloud
// transcription. Chinese-English recognition hints are safe defaults.
enum ASRTermVocabulary {
    static let maximumWords=300
    // meeting.json also carries persisted microphone/source diagnostics and
    // can exceed 16 KiB in a valid session. Match the coarse snapshot reader.
    static let meetingMetadataLimit=64*1024
    static func valid(_ word:String)->Bool {
        let count=word.unicodeScalars.count
        guard count>0,count<=128,word==word.trimmingCharacters(in:.whitespacesAndNewlines),
              !word.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0) || [.format,.privateUse,.unassigned].contains($0.properties.generalCategory)}) else{return false}
        if word.unicodeScalars.contains(where:{$0.value>127}) {return count<=15}
        return word.split(whereSeparator:{$0.isWhitespace}).count<=7
    }
    static func validated(_ words:[String:Int])throws->[String:Int] {
        guard words.count<=maximumWords,words.allSatisfy({valid($0.key) && (1...5).contains($0.value)}),
              let data=try? JSONSerialization.data(withJSONObject:words),data.count<=24576 else{throw Failure(code:"asr_terms_invalid")}
        return words
    }
    static func confirmedVocabulary(in folder:URL,session:String)throws->[String] {
        let manifest=folder.appendingPathComponent("meeting.json",isDirectory:false)
        let attributes=try manifest.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard attributes.isRegularFile==true,attributes.isSymbolicLink != true,
              let size=attributes.fileSize,size<=meetingMetadataLimit,
              manifest.standardizedFileURL==manifest.resolvingSymlinksInPath().standardizedFileURL,
              let value=try JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:Any],
              value["session"] as? String==session,
              value["cache_id"] as? String==nil || value["cache_id"] as? String==folder.lastPathComponent else {
            throw Failure(code:"asr_terms_scope_invalid")
        }
        guard value["asr_vocabulary_confirmed"] as? Bool==true else{return []}
        guard let raw=value["asr_vocabulary"] as? [String:Int] else{throw Failure(code:"asr_terms_invalid")}
        return try validated(raw).keys.sorted()
    }
    static func parameters(silenceMS:Int,words:[String:Int]=[:])throws->[String:Any] {
        let words=try validated(words)
        var parameters:[String:Any]=["format":"pcm","sample_rate":16000,"max_sentence_silence":silenceMS,
                                      "language_hints":["zh","en"]]
        if !words.isEmpty {parameters["vocabulary"]=words}
        return parameters
    }
    static func explicitVocabularyRejection(_ header:[String:Any])->Bool {
        guard header["error_code"] as? String=="InvalidParameter" else{return false}
        let message=(header["error_message"] as? String ?? "").lowercased()
        return message.contains("vocabulary") || message.contains("hotword")
    }
}
