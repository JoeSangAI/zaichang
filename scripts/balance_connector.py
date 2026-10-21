"""Alibaba BSS RPC signing/parsing only. No HTTP, credentials lookup or account access."""
import base64,hashlib,hmac,json,math
from decimal import Decimal,InvalidOperation
from urllib.parse import quote

def signed_balance_request(access_key_id,access_key_secret,*,timestamp,nonce):
    if not all(isinstance(x,str) and x for x in [access_key_id,access_key_secret,timestamp,nonce]):raise ValueError('missing signing fields')
    params={'Action':'QueryAccountBalance','Version':'2017-12-14','Format':'JSON','AccessKeyId':access_key_id,'SignatureMethod':'HMAC-SHA1','SignatureVersion':'1.0','SignatureNonce':nonce,'Timestamp':timestamp}
    canonical='&'.join(quote(k,safe='~')+'='+quote(v,safe='~') for k,v in sorted(params.items()))
    payload='GET&%2F&'+quote(canonical,safe='~')
    params['Signature']=base64.b64encode(hmac.new((access_key_secret+'&').encode(),payload.encode(),hashlib.sha1).digest()).decode()
    return {'endpoint':'https://business.aliyuncs.com/','method':'GET','params':params}

def parse_balance(response):
    if response.get('Success') is not True:raise ValueError('balance query failed')
    data=response.get('Data')
    if not isinstance(data,dict):raise ValueError('invalid balance response')
    values={}
    for field in ['AvailableCashAmount','AvailableAmount']:
        value=data.get(field)
        if isinstance(value,bool) or value is None:raise ValueError('missing balance amount')
        try:amount=Decimal(str(value).replace(',',''))
        except InvalidOperation:raise ValueError('invalid balance amount') from None
        if not amount.is_finite():raise ValueError('invalid balance amount')
        values[field]=str(amount)
    return {**values,'currency':data.get('Currency'),'basis':'account_balance_snapshot','free_model_quota':'unknown'}

class BalanceSnapshot:
    def __init__(self):self.value=None;self.checked_at=None;self.stale=False
    def accept(self,response,checked_at):
        try:value=parse_balance(response)
        except ValueError:
            self.stale=self.value is not None
            raise
        self.value=value;self.checked_at=checked_at;self.stale=False
