package com.trading.news.model;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.util.List;

public class NewsResponse {

    @JsonProperty("items")
    private String items;

    @JsonProperty("sentiment_score_definition")
    private String sentimentScoreDefinition;

    @JsonProperty("relevance_score_definition")
    private String relevanceScoreDefinition;

    @JsonProperty("feed")
    private List<NewsArticle> feed;

    public NewsResponse() {}

    public String getItems() {
        return items;
    }

    public void setItems(String items) {
        this.items = items;
    }

    public String getSentimentScoreDefinition() {
        return sentimentScoreDefinition;
    }

    public void setSentimentScoreDefinition(String sentimentScoreDefinition) {
        this.sentimentScoreDefinition = sentimentScoreDefinition;
    }

    public String getRelevanceScoreDefinition() {
        return relevanceScoreDefinition;
    }

    public void setRelevanceScoreDefinition(String relevanceScoreDefinition) {
        this.relevanceScoreDefinition = relevanceScoreDefinition;
    }

    public List<NewsArticle> getFeed() {
        return feed;
    }

    public void setFeed(List<NewsArticle> feed) {
        this.feed = feed;
    }
}