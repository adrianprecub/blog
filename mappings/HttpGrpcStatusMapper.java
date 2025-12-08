import io.grpc.Status;
import io.grpc.StatusRuntimeException;

public final class HttpGrpcStatusMapper {

    private HttpGrpcStatusMapper() {}

    public static Status fromHttp(int httpStatus) {
        switch (httpStatus) {
            case 200:
            case 201:
            case 204:
                return Status.OK;
            case 400:
                return Status.INVALID_ARGUMENT;
            case 401:
                return Status.UNAUTHENTICATED;
            case 403:
                return Status.PERMISSION_DENIED;
            case 404:
                return Status.NOT_FOUND;
            case 409:
                // default choice. Callers can refine to ALREADY_EXISTS or ABORTED.
                return Status.ABORTED;
            case 412:
                return Status.FAILED_PRECONDITION;
            case 413:
            case 415:
                return Status.INVALID_ARGUMENT;
            case 416:
                return Status.OUT_OF_RANGE;
            case 429:
                return Status.RESOURCE_EXHAUSTED;
            case 499:
                return Status.CANCELLED;
            case 500:
                return Status.INTERNAL;
            case 501:
                return Status.UNIMPLEMENTED;
            case 502:
                return Status.UNAVAILABLE;
            case 503:
                return Status.UNAVAILABLE;
            case 504:
                return Status.DEADLINE_EXCEEDED;
            default:
                if (httpStatus >= 400 && httpStatus < 500) {
                    return Status.INVALID_ARGUMENT;
                }
                if (httpStatus >= 500 && httpStatus < 600) {
                    return Status.INTERNAL;
                }
                return Status.UNKNOWN;
        }
    }

    public static int toHttp(Status.Code grpcCode) {
        switch (grpcCode) {
            case OK:
                return 200;
            case CANCELLED:
                return 499; // client closed request
            case UNKNOWN:
                return 500;
            case INVALID_ARGUMENT:
                return 400;
            case DEADLINE_EXCEEDED:
                return 504;
            case NOT_FOUND:
                return 404;
            case ALREADY_EXISTS:
                return 409;
            case PERMISSION_DENIED:
                return 403;
            case RESOURCE_EXHAUSTED:
                return 429;
            case FAILED_PRECONDITION:
                return 412;
            case ABORTED:
                return 409;
            case OUT_OF_RANGE:
                return 416;
            case UNIMPLEMENTED:
                return 501;
            case INTERNAL:
                return 500;
            case UNAVAILABLE:
                return 503;
            case DATA_LOSS:
                return 500;
            case UNAUTHENTICATED:
                return 401;
            default:
                return 500;
        }
    }

    public static void throwIfNotOk(int httpStatus) {
        Status status = fromHttp(httpStatus);
        if (!status.isOk()) {
            throw status.asRuntimeException();
        }
    }
}