import unittest
from scripts.balance_connector import signed_balance_request,parse_balance,BalanceSnapshot
class BalanceTests(unittest.TestCase):
    def response(self):return {'Success':True,'Data':{'AvailableCashAmount':'1,234.56','AvailableAmount':'2345.67','Currency':'CNY'}}
    def test_sign_only_no_network(self):
        r=signed_balance_request('fake-id','fake-secret',timestamp='2026-10-02T00:00:00Z',nonce='fake-nonce')
        self.assertEqual(r['params']['Action'],'QueryAccountBalance');self.assertNotIn('fake-secret',str(r));self.assertEqual(r['params']['Signature'],'oFUbqyehzSNQ/gOrEtE3dORz+5o=')
    def test_cash_credit_and_free_quota_separate(self):
        r=parse_balance(self.response());self.assertEqual(r['AvailableCashAmount'],'1234.56');self.assertEqual(r['AvailableAmount'],'2345.67');self.assertEqual(r['free_model_quota'],'unknown')
    def test_failure_keeps_snapshot_stale_not_zero(self):
        s=BalanceSnapshot();s.accept(self.response(),'fake-time')
        with self.assertRaises(ValueError):s.accept({'Success':False},'next')
        self.assertTrue(s.stale);self.assertEqual(s.value['AvailableCashAmount'],'1234.56');self.assertEqual(s.checked_at,'fake-time')
    def test_invalid_amount(self):
        for x in [True,None,'NaN']:
            r=self.response();r['Data']['AvailableCashAmount']=x
            with self.assertRaises(ValueError):parse_balance(r)
