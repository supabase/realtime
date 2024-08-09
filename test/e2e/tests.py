import os
import supabase
from supabase.lib.client_options import ClientOptions
from dotenv import load_dotenv

load_dotenv()

PROJECT_URL = os.getenv("PROJECT_URL")
PROJECT_ANON_TOKEN = os.getenv("PROJECT_ANON_TOKEN")

default_realtime_heartbeat_config = {"heartbeatIntervalMs": 1000, "timeout": 1000}
default_realtime_config = {"config": {"broadcast": {"self": True}}}
opts = ClientOptions(realtime=default_realtime_config)
supabase_client = supabase.create_client(PROJECT_URL, PROJECT_ANON_TOKEN, opts)

def test_broadcast_able_to_self_broadcast():
    print("POTATO")
    print(supabase_client.realtime)
    assert False
def test_broadcast_able_to_use_endpoint():
    assert True
def test_broadcast_not_able_to_connect_if_missing_permissions():
    assert True
def test_broadcast_able_to_connect_if_has_permissions():
    user = supabase_client.auth.sign_in_with_password({ "email": "test1@test.com", "password": "test_test" })
    print(user)
    assert True
    supabase_client.auth.sign_out()