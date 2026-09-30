"""Inspect existing prepared claim JSON without exposing personal details."""
from __future__ import annotations
import collections
import gzip
import hashlib
import json
import re
from decimal import Decimal, InvalidOperation
from pathlib import Path

MANIFEST=Path('.local_data/assist365/bigquery-load/smoke-20260929/load_manifest.json')
OUT=Path('.local_data/assist365/claims_audit')


def leaves(value, prefix=''):
    if isinstance(value,dict):
        for key,item in value.items():
            yield from leaves(item, prefix+'.'+key if prefix else key)
    elif isinstance(value,list):
        for item in value:
            yield from leaves(item,prefix+'[]')
    else:
        yield prefix,value


def profile():
    manifest=json.loads(MANIFEST.read_text())
    resource=next(x for x in manifest['resources'] if x['resource']=='siniestros')
    seen={}; duplicate=0; conflicts=0
    negative=[]; missing=[]; positive=collections.defaultdict(list)
    key_counts=collections.Counter(); currency_kinds=collections.Counter()
    with gzip.open(resource['load_file'],'rt') as source:
        for line in source:
            payload=json.loads(line)['payload']
            if isinstance(payload,str):payload=json.loads(payload)
            claim_id=payload.get('claim_id')
            digest=hashlib.sha256(json.dumps(payload,sort_keys=True).encode()).hexdigest()
            if claim_id in seen:
                duplicate+=1;conflicts+=seen[claim_id]!=digest;continue
            seen[claim_id]=digest
            amount=payload.get('amount') or {}; currency=amount.get('currency')
            try: value=Decimal(str(amount.get('value')))
            except InvalidOperation:value=None
            raw_leaves=list(leaves(payload))
            signature=[path for path,v in raw_leaves if re.search(r'refund|reversal|reintegro|revers|adjustment|ajuste|original_claim|reference_claim',path,re.I)]
            flag_values=sum(1 for path,v in raw_leaves if isinstance(v,str) and re.search(r'\b(refund|reversal|reintegro|reverso|adjustment|ajuste)\b',v,re.I))
            entry={'siniestro_id':claim_id,'poliza_id':payload.get('policy_id'),'estado':payload.get('status'),
                   'tipo':payload.get('type'),'fecha':payload.get('occurred_at'),'monto':str(value),
                   'moneda':currency if isinstance(currency,str) else None,
                   'adjustment_fields':signature,'adjustment_text_matches':flag_values,
                   'payload_sha256':digest}
            if value is not None and value.is_finite() and value>0:
                positive[(entry['poliza_id'],entry['moneda'],value)].append(entry)
            if value is not None and value.is_finite() and value<0:
                entry['alternate_currency_paths']=[path for path,v in raw_leaves if re.search(r'currency|moneda',path,re.I) and not path.startswith('amount.currency') and isinstance(v,str) and v.upper()!='NAN' and re.fullmatch(r'[A-Za-z]{3}',v)]
                negative.append(entry)
            if not isinstance(currency,str):
                currency_kinds[json.dumps(currency,sort_keys=True)]+=1
                entry['alternate_currency_paths']=[path for path,v in raw_leaves if re.search(r'currency|moneda',path,re.I) and not path.startswith('amount.currency') and isinstance(v,str) and v.upper()!='NAN' and re.fullmatch(r'[A-Za-z]{3}',v)]
                key_counts.update(path for path,v in raw_leaves)
                missing.append(entry)
    for row in negative:
        candidates=positive.get((row['poliza_id'],row['moneda'],-Decimal(row['monto'])),[])
        row['opposite_amount_same_policy_currency']=len(candidates)
        row['opposite_amount_same_type_date']=sum(x['tipo']==row['tipo'] and x['fecha']==row['fecha'] for x in candidates)
    result={'source_run':manifest['run_id'],'unique_claims':len(seen),'exact_duplicates':duplicate,'conflicting_ids':conflicts,
            'negative_total':len(negative),'negative_by_status':dict(collections.Counter(x['estado'] for x in negative)),
            'negative_with_adjustment_fields':sum(bool(x['adjustment_fields']) for x in negative),
            'negative_with_adjustment_text':sum(bool(x['adjustment_text_matches']) for x in negative),
            'negative_with_opposite_amount_same_policy_currency':sum(bool(x['opposite_amount_same_policy_currency']) for x in negative),
            'negative_with_opposite_amount_same_type_date':sum(bool(x['opposite_amount_same_type_date']) for x in negative),
            'missing_currency_total':len(missing),'missing_currency_by_status':dict(collections.Counter(x['estado'] for x in missing)),
            'missing_currency_representations':dict(currency_kinds),
            'missing_currency_with_alternate_currency':sum(bool(x['alternate_currency_paths']) for x in missing),
            'missing_currency_payload_paths':dict(key_counts),
            'negative_and_missing_currency':len({x['siniestro_id'] for x in negative}&{x['siniestro_id'] for x in missing})}
    OUT.mkdir(parents=True,exist_ok=True)
    (OUT/'raw_profile.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    (OUT/'claim_issues.json').write_text(json.dumps({'negative':negative,'missing_currency':missing},ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(result,ensure_ascii=False))


if __name__=='__main__':profile()
