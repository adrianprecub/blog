package com.trading.news.model;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.util.List;

public class NewsArticle {

    @JsonProperty("title")
    private String title;

    @JsonProperty("url")
    private String url;

    @JsonProperty("time_published")
    private String timePublished;

    @JsonProperty("authors")
    private List<String> authors;

    @JsonProperty("summary")
    private String summary;

    @JsonProperty("banner_image")
    private String bannerImage;

    @JsonProperty("source")
    private String source;

    @JsonProperty("category_within_source")
    private String categoryWithinSource;

    @JsonProperty("source_domain")
    private String sourceDomain;

    @JsonProperty("topics")
    private List<Topic> topics;

    @JsonProperty("overall_sentiment_score")
    private Double overallSentimentScore;

    @JsonProperty("overall_sentiment_label")
    private String overallSentimentLabel;

    public NewsArticle() {}

    public String getTitle() {
        return title;
    }

    public void setTitle(String title) {
        this.title = title;
    }

    public String getUrl() {
        return url;
    }

    public void setUrl(String url) {
        this.url = url;
    }

    public String getTimePublished() {
        return timePublished;
    }

    public void setTimePublished(String timePublished) {
        this.timePublished = timePublished;
    }

    public List<String> getAuthors() {
        return authors;
    }

    public void setAuthors(List<String> authors) {
        this.authors = authors;
    }

    public String getSummary() {
        return summary;
    }

    public void setSummary(String summary) {
        this.summary = summary;
    }

    public String getBannerImage() {
        return bannerImage;
    }

    public void setBannerImage(String bannerImage) {
        this.bannerImage = bannerImage;
    }

    public String getSource() {
        return source;
    }

    public void setSource(String source) {
        this.source = source;
    }

    public String getCategoryWithinSource() {
        return categoryWithinSource;
    }

    public void setCategoryWithinSource(String categoryWithinSource) {
        this.categoryWithinSource = categoryWithinSource;
    }

    public String getSourceDomain() {
        return sourceDomain;
    }

    public void setSourceDomain(String sourceDomain) {
        this.sourceDomain = sourceDomain;
    }

    public List<Topic> getTopics() {
        return topics;
    }

    public void setTopics(List<Topic> topics) {
        this.topics = topics;
    }

    public Double getOverallSentimentScore() {
        return overallSentimentScore;
    }

    public void setOverallSentimentScore(Double overallSentimentScore) {
        this.overallSentimentScore = overallSentimentScore;
    }

    public String getOverallSentimentLabel() {
        return overallSentimentLabel;
    }

    public void setOverallSentimentLabel(String overallSentimentLabel) {
        this.overallSentimentLabel = overallSentimentLabel;
    }

    public static class Topic {
        @JsonProperty("topic")
        private String topic;

        @JsonProperty("relevance_score")
        private String relevanceScore;

        public String getTopic() {
            return topic;
        }

        public void setTopic(String topic) {
            this.topic = topic;
        }

        public String getRelevanceScore() {
            return relevanceScore;
        }

        public void setRelevanceScore(String relevanceScore) {
            this.relevanceScore = relevanceScore;
        }
    }
}