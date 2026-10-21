import Foundation

// Describes the recording condition, never a person's identity. Missing old
// context remains unknown; it is not guessed from a person's name or voice.
struct VoiceprintAcousticContext:Codable,Equatable,Hashable {
    let channel:String
    let deviceFingerprint:String?
    let environmentLabel:String?
    init(channel:String,deviceFingerprint:String?=nil,environmentLabel:String?=nil) {
        self.channel=channel;self.deviceFingerprint=deviceFingerprint;self.environmentLabel=environmentLabel
    }
    var valid:Bool {
        guard ["microphone","system"].contains(channel) else{return false}
        if let deviceFingerprint,deviceFingerprint.range(of:"^[0-9a-f]{64}$",options:.regularExpression)==nil{return false}
        if let environmentLabel {
            guard !environmentLabel.isEmpty,environmentLabel.count<=40,environmentLabel==environmentLabel.trimmingCharacters(in:.whitespacesAndNewlines),
                  !environmentLabel.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format}) else{return false}
        }
        return true
    }
    static func channel(for source:String)->String {(source=="mic" || source.range(of:"^mic-g[1-9][0-9]{0,2}$",options:.regularExpression) != nil) ? "microphone":"system"}
}
struct VoiceprintSample:Codable,Equatable {
    let session:String;let source:String;let epoch:String;let start:Double;let end:Double;let vector:[Double]
    let context:VoiceprintAcousticContext?
    init(session:String,source:String,epoch:String,start:Double,end:Double,vector:[Double],context:VoiceprintAcousticContext?=nil) {
        self.session=session;self.source=source;self.epoch=epoch;self.start=start;self.end=end;self.vector=vector;self.context=context
    }
}
