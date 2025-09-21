package com.trading.news;

import com.trading.news.model.NewsResponse;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.QueryParam;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.eclipse.microprofile.rest.client.inject.RestClient;

@Path("/trading/news")
public class TradingNewsService {

    public static final String NEWS_SENTIMENT_FUNCTION = "NEWS_SENTIMENT";
    public static final String CATEGORY = "general";

    private final AlphaVantageNewsClient newsClient;
    private final String apiKey;

    public TradingNewsService(@RestClient AlphaVantageNewsClient newsClient,
                              @ConfigProperty(name = "alphaVantage.api.key") String apiKey) {
        this.newsClient = newsClient;
        this.apiKey = apiKey;
    }

    @Path("general")
    @GET
    public NewsResponse getGeneralNews() {
        return newsClient.getNewsByCategory(NEWS_SENTIMENT_FUNCTION, CATEGORY, apiKey);
    }

    @Path("tickers")
    @GET
    public NewsResponse getNewsByTickers(@QueryParam("tickers") String tickers) {
        return newsClient.getNewsByTickers("NEWS_SENTIMENT", tickers, apiKey);
    }
}