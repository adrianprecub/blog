package com.jobrunr;

import org.jobrunr.configuration.JobRunr;
import org.jobrunr.scheduling.BackgroundJob;
import org.jobrunr.scheduling.carbonaware.CarbonAware;
import org.jobrunr.scheduling.cron.Cron;
import org.jobrunr.storage.InMemoryStorageProvider;

import java.time.LocalDateTime;

import static java.time.temporal.ChronoUnit.HOURS;

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

        //every 5 minutes job
        BackgroundJob.scheduleRecurrently(Cron.every5minutes(), () -> myService.every5MinJob());

        //last day of the month job
        BackgroundJob.scheduleRecurrently(Cron.lastDayOfTheMonth(23), () -> myService.lastDayOfMonthJob());

        //carbon aware job
        LocalDateTime now = LocalDateTime.now();
        BackgroundJob.schedule(CarbonAware.between(now, now.plus(5, HOURS)), () -> myService.carbonAwareJob());
    }

}