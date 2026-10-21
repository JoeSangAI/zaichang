import Foundation

// Deliberately narrow local language rule, not general identity inference. Names
// must be stated by the same acoustic speaker in two independent introductions.
// Mentioning, quoting, addressing or discussing someone never names the speaker.
struct SemanticNameEvidence:Codable,Equatable {
    let id:String;let revision:Int;let start:Double;let end:Double
}
struct SessionSemanticName:Codable,Equatable {
    let key:SessionSpeakerKey;let name:String;let support:[SemanticNameEvidence]
}
struct LocalSemanticNames {
    private struct Intro {let key:SessionSpeakerKey;let name:String;let ref:SemanticNameEvidence}
    private var introductions:[String:Intro]=[:]
    static func explicitIntroduction(_ text:String)->String? {
        let text=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard text.count<=200,!text.contains(where:{"\"'“”‘’「」『』？?".contains($0)}) else{return nil}
        // Only a complete literal self-naming sentence. Role claims, quoted speech
        // and introductions embedded in a longer narrative remain unsupported.
        let pattern="^(?:(?:大家好|你好|您好)[，,。!！ ]*)?(?:我叫|我的名字是|我的名字叫)[ ]*([\\p{Han}]{2,4}|[A-Za-z][A-Za-z -]{1,23})[ ]*[。.!！]?$"
        guard let expression=try? NSRegularExpression(pattern:pattern),
              let match=expression.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)),
              let range=Range(match.range(at:1),in:text) else{return nil}
        let name=String(text[range]).trimmingCharacters(in:.whitespaces)
        let denied:Set<String>=["什么名字","你的名字","一个人","大家","你们","他们","老师","老板","医生","学生","负责人","朋友","someone","nobody","myself"]
        guard !denied.contains(name.lowercased()),!name.hasSuffix("老师"),!name.hasSuffix("经理"),!name.hasSuffix("总") else{return nil}
        if name.unicodeScalars.allSatisfy({$0.value>=0x3400 && $0.value<=0x9fff}) {
            let surnames="赵钱孙李周吴郑王冯陈褚卫蒋沈韩杨朱秦尤许何吕施张孔曹严华金魏陶姜戚谢邹喻柏水窦章云苏潘葛奚范彭郎鲁韦昌马苗凤花方俞任袁柳鲍史唐费廉岑薛雷贺倪汤滕殷罗毕郝邬安常乐于时傅皮卞齐康伍余元卜顾孟平黄和穆萧尹姚邵湛汪祁毛禹狄米贝明臧计伏成戴谈宋茅庞熊纪舒屈项祝董梁杜阮蓝闵席季麻强贾路娄危江童颜郭梅盛林刁钟徐邱骆高夏蔡田樊胡凌霍虞万支柯管卢莫经房裘缪干解应宗丁宣邓郁单杭洪包诸左石崔吉龚程嵇邢滑裴陆荣翁荀羊甄曲封芮储靳段富巫乌焦巴弓牧隗山谷车侯宓蓬全郗班仰秋仲伊宫宁仇栾暴甘钭厉戎祖武符刘景詹束龙叶幸司韶郜黎蓟薄印宿白怀蒲台从鄂索咸籍赖卓蔺屠蒙池乔阴胥能苍双闻莘党翟谭贡劳逄姬申扶堵冉宰郦雍郤璩桑桂濮牛寿通边扈燕冀郏浦尚农温别庄晏柴瞿阎充慕连茹习艾鱼容向古易慎戈廖庾终暨居衡步都耿满弘匡国文寇广禄阙东欧殳沃利蔚越夔隆师巩厍聂晁勾敖融冷訾辛阚那简饶空曾毋沙乜养鞠须丰巢关蒯相查后荆红游竺权逯盖益桓公"
            guard let first=name.first,surnames.contains(first) else{return nil}
        }
        return name
    }
    mutating func observe(_ event:[String:Any])->Set<SessionSpeakerKey> {
        guard let id=event["segment_id"] as? String,id.count<=256 else{return []}
        var changed=Set<SessionSpeakerKey>()
        if let previous=introductions.removeValue(forKey:id) {changed.insert(previous.key)}
        guard event["final"] as? Bool==true,event["end_time_known"] as? Bool==true,
              (event["quality_flags"] as? [String] ?? []).isEmpty,
              let key=SessionSpeakerKey.from(event),
              (event["speaker"] as? [String:Any])?["basis"] as? String=="anonymous_cluster",
              let revision=event["revision"] as? Int,revision>=0,
              let start=event["start"] as? Double,let end=event["end"] as? Double,
              start.isFinite,end.isFinite,start>=0,end-start>=0.8,end-start<=60,
              let text=event["text"] as? String,let name=Self.explicitIntroduction(text),
              introductions.count<1024 else{return changed}
        introductions[id]=Intro(key:key,name:name,ref:SemanticNameEvidence(id:id,revision:revision,start:start,end:end));changed.insert(key)
        return changed
    }
    mutating func restore(_ saved:SessionSemanticName) {for ref in saved.support {introductions[ref.id]=Intro(key:saved.key,name:saved.name,ref:ref)}}
    mutating func discard(_ ids:Set<String>) {for id in ids {introductions.removeValue(forKey:id)}}
    func recommendation(_ key:SessionSpeakerKey)->SessionSemanticName? {
        let rows=introductions.values.filter{$0.key==key}.sorted{$0.ref.start<$1.ref.start}
        guard Set(rows.map(\.name)).count==1,let name=rows.first?.name else{return nil}
        var independent:[SemanticNameEvidence]=[]
        for row in rows where !independent.contains(where:{$0.start<row.ref.end && $0.end>row.ref.start}) {
            independent.append(row.ref);if independent.count==8 {break}
        }
        guard independent.count>=2 else{return nil}
        return SessionSemanticName(key:key,name:name,support:independent)
    }
}
