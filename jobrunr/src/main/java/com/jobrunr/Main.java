package com.jobrunr;

import org.jobrunr.configuration.JobRunr;
import org.jobrunr.scheduling.BackgroundJob;
import org.jobrunr.storage.InMemoryStorageProvider;

import java.time.LocalDateTime;

public class Main {
    public static void main(String[] args) {

        System.out.printf("Hello and welcome!");
        JobRunr
                .configure()
                .useStorageProvider(new InMemoryStorageProvider())
                .useDashboard()
                .useBackgroundJobServer()
                .initialize();

        BackgroundJob.enqueue(() -> System.out.println("This is a background job!"));
        BackgroundJob.schedule(LocalDateTime.now().plusMinutes(5), () -> System.out.println("This is a scheduled job!"));
    }
}