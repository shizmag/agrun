# Incomplete independently authored infrastructure fixture.
class RetryError(Exception):
    pass
class Retrying:
    def __init__(self, *args, **kwargs):
        pass
def retry(*args, **kwargs):
    def decorate(function):
        return function
    return decorate
