package com.trading.news;

import com.trading.news.model.NewsResponse;
import io.quarkiverse.mcp.server.Tool;
import io.quarkiverse.mcp.server.ToolArg;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.eclipse.microprofile.rest.client.inject.RestClient;


public class AlphaVantageTools {

    public static final String NEWS_SENTIMENT_FUNCTION = "NEWS_SENTIMENT";
    public static final String CATEGORY = "general";

    private final AlphaVantageNewsClient newsClient;
    private final String apiKey;

    public AlphaVantageTools(@RestClient AlphaVantageNewsClient newsClient,
                             @ConfigProperty(name = "alphaVantage.api.key") String apiKey) {
        this.newsClient = newsClient;
        this.apiKey = apiKey;
    }

    @Tool(description = "Get general trading news.")
    NewsResponse get_trading_news() {
        return newsClient.getNewsByCategory(NEWS_SENTIMENT_FUNCTION, CATEGORY, apiKey);
    }

    @Tool(description = "Get trading news by comma-separated tickers.")
    NewsResponse get_trading_news_by_tickers(@ToolArg(description = "Tickers for which to get the trading news.", required = true) String tickers) {
        return newsClient.getNewsByTickers(NEWS_SENTIMENT_FUNCTION, tickers, apiKey);
    }
}
