package com.jobrunr;

import org.jobrunr.configuration.JobRunr;
import org.jobrunr.scheduling.BackgroundJob;
import org.jobrunr.storage.InMemoryStorageProvider;

import java.time.LocalDateTime;

public class Main {
    public static void main(String[] args) {
        //configure JobRunr
        JobRunr
                .configure()
                //provide in memory storage
                .useStorageProvider(new InMemoryStorageProvider())
                .useDashboard()
                .useBackgroundJobServer()
                .initialize();

        MyService myService = new MyService();

        //one time job
        BackgroundJob.enqueue(() -> myService.enqueuedJob());

        //scheduled job
        BackgroundJob.schedule(LocalDateTime.now().plusMinutes(5), () -> myService.scheduledJob());

        //recurring job
        BackgroundJob.scheduleRecurrently("my-recurring-job", "*/1 * * * *", () -> myService.recurringJob());
    }
}