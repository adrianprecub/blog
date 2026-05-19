import Foundation

struct ExtractionResult: Decodable, Sendable, Equatable {
    let title: String
    let summary: String
    let keyIdeas: [String]
    let topics: [String]
    let actionItems: [ActionItem]
    let entities: Entities
    let cleanedTranscript: String

    init(
        title: String,
        summary: String,
        keyIdeas: [String],
        topics: [String],
        actionItems: [ActionItem],
        entities: Entities,
        cleanedTranscript: String
    ) {
        self.title = title
        self.summary = summary
        self.keyIdeas = keyIdeas
        self.topics = topics
        self.actionItems = actionItems
        self.entities = entities
        self.cleanedTranscript = cleanedTranscript
    }

    enum CodingKeys: String, CodingKey {
        case title, summary, keyIdeas, topics, actionItems, entities, cleanedTranscript
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "Untitled"
        self.summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? ""
        self.keyIdeas = (try? c.decodeIfPresent([String].self, forKey: .keyIdeas)) ?? []
        self.topics = (try? c.decodeIfPresent([String].self, forKey: .topics)) ?? []
        self.actionItems = (try? c.decodeIfPresent([ActionItem].self, forKey: .actionItems)) ?? []
        self.entities = (try? c.decodeIfPresent(Entities.self, forKey: .entities)) ?? Entities(people: [], places: [], orgs: [])
        self.cleanedTranscript = (try? c.decodeIfPresent(String.self, forKey: .cleanedTranscript)) ?? ""
    }
}

struct ActionItem: Decodable, Sendable, Equatable {
    let task: String
    let owner: String?
    let due: String?

    init(task: String, owner: String?, due: String?) {
        self.task = task
        self.owner = owner
        self.due = due
    }

    enum CodingKeys: String, CodingKey { case task, owner, due }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.task = (try? c.decodeIfPresent(String.self, forKey: .task)) ?? ""
        self.owner = try? c.decodeIfPresent(String.self, forKey: .owner)
        self.due = try? c.decodeIfPresent(String.self, forKey: .due)
    }
}

struct Entities: Decodable, Sendable, Equatable {
    let people: [String]
    let places: [String]
    let orgs: [String]

    init(people: [String], places: [String], orgs: [String]) {
        self.people = people
        self.places = places
        self.orgs = orgs
    }

    enum CodingKeys: String, CodingKey { case people, places, orgs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.people = (try? c.decodeIfPresent([String].self, forKey: .people)) ?? []
        self.places = (try? c.decodeIfPresent([String].self, forKey: .places)) ?? []
        self.orgs = (try? c.decodeIfPresent([String].self, forKey: .orgs)) ?? []
    }
}
