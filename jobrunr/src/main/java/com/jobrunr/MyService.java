package com.jobrunr;

public class MyService {

    public void enqueuedJob() {
        System.out.println("Enqueued Job executed!");
    }

    public void scheduledJob() {
        System.out.println("Scheduled Job executed!");
    }

    public void every5MinJob() {
        System.out.println("Every 5 Minutes Job executed!");
    }

    public void recurringJob() {
        System.out.println("Recurring Job executed!");
    }

    public void lastDayOfMonthJob() {
        System.out.println("Last Day of the Month Job executed!");
    }

    public void carbonAwareJob() {
        System.out.println("This job runs when the carbon intensity is low");
    }
}
