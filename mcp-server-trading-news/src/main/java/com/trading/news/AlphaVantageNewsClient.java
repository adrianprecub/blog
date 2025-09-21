package com.trading.news;

import com.trading.news.model.NewsResponse;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.MediaType;
import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

@Path("/query")
@RegisterRestClient(configKey="alphavantagenews")
@Produces(MediaType.APPLICATION_JSON)
public interface AlphaVantageNewsClient {

    @GET
    NewsResponse getNewsByCategory(
            @QueryParam("function") String function,
            @QueryParam("topics") String topics,
            @QueryParam("apikey") String apiKey
    );

    @GET
    NewsResponse getNewsByTickers(
            @QueryParam("function") String function,
            @QueryParam("tickers") String tickers,
            @QueryParam("apikey") String apiKey
    );


}
